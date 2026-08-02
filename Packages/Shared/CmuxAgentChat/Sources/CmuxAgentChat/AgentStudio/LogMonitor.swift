import Foundation

/// Real-time log tailer and event parser for AI CLI JSONL transcript files.
///
/// Uses macOS ``DispatchSourceFileSystemObject`` to monitor files (`~/.claude/...`, `~/.antigravity/...`, `~/.codex/...`)
/// for new line appends and parses them incrementally into ``CanonicalEvent`` items.
public final class LogMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var fileDescriptor: CInt = -1
    private var dispatchSource: (any DispatchSourceFileSystemObject)?
    private var currentOffset: UInt64 = 0
    private var lineBuffer: String = ""
    private var directorySource: (any DispatchSourceFileSystemObject)?

    /// Target file path to monitor.
    public let filePath: String

    /// Whether to read existing file content from the beginning upon starting.
    public var readFromBeginning: Bool

    /// Callback fired whenever a complete text line is read.
    public var onLineParsed: ((String) -> Void)?

    /// Callback fired whenever a ``CanonicalEvent`` is parsed from a JSON line.
    public var onEventParsed: ((CanonicalEvent) -> Void)?

    /// Whether the log monitor is currently actively watching the file.
    public private(set) var isMonitoring: Bool = false

    /// Initialize a new LogMonitor for a file path.
    public init(filePath: String, readFromBeginning: Bool = true) {
        self.filePath = (filePath as NSString).expandingTildeInPath
        self.readFromBeginning = readFromBeginning
    }

    deinit {
        stopMonitoring()
    }

    /// Start watching the log file for updates.
    public func startMonitoring() {
        lock.lock()
        guard !isMonitoring else {
            lock.unlock()
            return
        }
        isMonitoring = true
        lock.unlock()

        openAndWatchFile()
    }

    /// Stop monitoring the log file.
    public func stopMonitoring() {
        lock.lock()
        guard isMonitoring else {
            lock.unlock()
            return
        }
        isMonitoring = false

        flushLineBufferLocked()

        if let source = dispatchSource {
            source.cancel()
            dispatchSource = nil
        } else if fileDescriptor != -1 {
            close(fileDescriptor)
        }
        fileDescriptor = -1

        if let dirSource = directorySource {
            dirSource.cancel()
            directorySource = nil
        }
        lock.unlock()
    }

    private func flushLineBufferLocked() {
        let trimmed = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        lineBuffer = ""
        guard !trimmed.isEmpty else { return }

        let lines = trimmed.components(separatedBy: "\n")
        for line in lines {
            let lineTrimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineTrimmed.isEmpty else { continue }

            onLineParsed?(lineTrimmed)

            if let event = CanonicalEvent.parseLine(lineTrimmed) {
                onEventParsed?(event)
            }
        }
    }

    /// Force an immediate manual check and read of the file content.
    public func readPendingContent() {
        lock.lock()
        defer { lock.unlock() }
        readAppendedLines()
    }

    // MARK: - Internal File Watching

    private func openAndWatchFile() {
        let fm = FileManager.default

        if !fm.fileExists(atPath: filePath) {
            watchParentDirectory()
            return
        }

        let fd = open(filePath, O_RDONLY)
        guard fd != -1 else {
            watchParentDirectory()
            return
        }

        lock.lock()
        self.fileDescriptor = fd

        // Determine starting offset
        if !readFromBeginning {
            let fileAttributes = try? fm.attributesOfItem(atPath: filePath)
            let fileSize = (fileAttributes?[.size] as? NSNumber)?.uint64Value ?? 0
            self.currentOffset = fileSize
        } else {
            self.currentOffset = 0
        }

        let queue = DispatchQueue(label: "com.agentstudio.logmonitor.\(UUID().uuidString)")
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.handleFileDeletedOrRenamed()
            } else if flags.contains(.write) || flags.contains(.extend) {
                self.lock.lock()
                self.readAppendedLines()
                self.lock.unlock()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        self.dispatchSource = source
        source.resume()

        // Initial catch-up read
        readAppendedLines()
        lock.unlock()
    }

    private func handleFileDeletedOrRenamed() {
        lock.lock()
        if let source = dispatchSource {
            source.cancel()
            dispatchSource = nil
        }
        fileDescriptor = -1
        currentOffset = 0
        lock.unlock()

        watchParentDirectory()
    }

    private func watchParentDirectory() {
        let parentDir = (filePath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: parentDir) {
            try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        let dirFd = open(parentDir, O_EVTONLY)
        guard dirFd != -1 else { return }

        let queue = DispatchQueue(label: "com.agentstudio.logmonitor.dir.\(UUID().uuidString)")
        let dirSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFd,
            eventMask: [.write, .extend],
            queue: queue
        )

        dirSource.setEventHandler { [weak self] in
            guard let self = self else { return }
            if fm.fileExists(atPath: self.filePath) {
                self.lock.lock()
                if let ds = self.directorySource {
                    ds.cancel()
                    self.directorySource = nil
                }
                self.lock.unlock()
                self.openAndWatchFile()
            }
        }

        dirSource.setCancelHandler {
            close(dirFd)
        }

        lock.lock()
        self.directorySource = dirSource
        dirSource.resume()
        lock.unlock()
    }

    /// Read newly written lines from `currentOffset` to current end of file.
    /// Caller MUST hold `lock` or execute inside synchronized context.
    private func readAppendedLines() {
        guard fileDescriptor != -1 else { return }

        let fileHandle = FileHandle(forReadingAtPath: filePath)
        guard let handle = fileHandle else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: currentOffset)
            let data = handle.readDataToEndOfFile()
            guard !data.isEmpty else { return }

            currentOffset += UInt64(data.count)

            guard let text = String(data: data, encoding: .utf8) else { return }

            lineBuffer += text
            processBufferedLines()
        } catch {
            // Handle truncation or seek error
            currentOffset = 0
        }
    }

    private func processBufferedLines() {
        let parts = lineBuffer.components(separatedBy: "\n")
        guard parts.count > 1 else { return }

        // All parts except the last one are completed lines
        let completeLines = parts.dropLast()
        // The last part is incomplete remainder to stay in lineBuffer
        lineBuffer = parts.last ?? ""

        for line in completeLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            onLineParsed?(trimmed)

            if let event = CanonicalEvent.parseLine(trimmed) {
                onEventParsed?(event)
            }
        }
    }
}
