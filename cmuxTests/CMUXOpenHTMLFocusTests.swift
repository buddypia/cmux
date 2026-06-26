import Darwin
import Foundation
import Testing

final class CMUXOpenHTMLFocusTests {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }
    }

    @Test func testOpenCommandRoutesLocalHTMLToDefaultBrowser() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("open-html")
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let htmlURL = rootURL.appendingPathComponent("gallery.html")
        let fakeOpenURL = rootURL.appendingPathComponent("open", isDirectory: false)
        let openLogURL = rootURL.appendingPathComponent("open-args.txt", isDirectory: false)
        let openEnvLogURL = rootURL.appendingPathComponent("open-env.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "<!doctype html><title>Gallery</title>\n".write(to: htmlURL, atomically: true, encoding: .utf8)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        defer {
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["open", htmlURL.path],
            environmentOverrides: [
                "CMUX_SOCKET": socketPath,
                "CMUX_SOCKET_PASSWORD": "stale-password",
                "CMUX_SOCKET_ENABLE": "0",
                "CMUX_SOCKET_MODE": "off",
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
                "CMUX_WORKSPACE_ID": "workspace:stale",
                "CMUX_PANEL_ID": "panel:stale",
                "CMUX_SURFACE_ID": "surface:stale",
                "CMUX_TAB_ID": "tab:stale",
                "CMUX_TEST_OPEN_TOOL_PATH": fakeOpenURL.path,
                "CMUX_TEST_OPEN_LOG": openLogURL.path,
                "CMUX_TEST_OPEN_ENV_LOG": openEnvLogURL.path
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "OK urls=1\n")
        let openArguments = try readFakeOpenArguments(from: openLogURL)
        #expect(openArguments == [htmlURL.standardizedFileURL.path])

        let openEnvironment = try readFakeOpenEnvironment(from: openEnvLogURL)
        for strippedKey in [
            "CMUX_ALLOW_SOCKET_OVERRIDE",
            "CMUX_SOCKET",
            "CMUX_SOCKET_ENABLE",
            "CMUX_SOCKET_MODE",
            "CMUX_SOCKET_PASSWORD",
            "CMUX_SOCKET_PATH",
            "CMUX_PANEL_ID",
            "CMUX_SURFACE_ID",
            "CMUX_TAB_ID",
            "CMUX_WORKSPACE_ID",
        ] {
            #expect(
                !openEnvironment.contains { $0.hasPrefix("\(strippedKey)=") },
                Comment(rawValue: "\(strippedKey) leaked to LaunchServices open environment: \(openEnvironment)")
            )
        }
    }

    @Test func testOpenCommandDoesNotInheritCallerSurfaceForExplicitWorkspace() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("open-workspace")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "notes\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }

            let params = payload["params"] as? [String: Any] ?? [:]
            guard method == "file.open",
                  params["workspace_id"] as? String == "workspace:99",
                  params["surface_id"] == nil else {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": method])
            }
            return Self.v2Response(id: id, ok: true, result: ["surface_id": "surface-id", "pane_id": "pane-id"])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["open", fileURL.path, "--workspace", "workspace:99"],
            environmentOverrides: [
                "CMUX_WORKSPACE_ID": "caller-workspace",
                "CMUX_SURFACE_ID": "caller-surface"
            ]
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "OK files=1 surface=surface-id pane=pane-id\n")
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private func runCLI(
        cliPath: String,
        socketPath: String,
        arguments: [String],
        environmentOverrides: [String: String] = [:]
    ) -> ProcessRunResult {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environmentOverrides.forEach { environment[$0.key] = $0.value }
        return runProcess(executablePath: cliPath, arguments: arguments, environment: environment, timeout: 15)
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(status: timedOut ? 124 : process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }

        return fd
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private func fakeOpenScript() -> String {
        """
        #!/bin/sh
        : "${CMUX_TEST_OPEN_LOG:?}"
        : > "$CMUX_TEST_OPEN_LOG"
        printf 'fake open stdout should be suppressed\\n'
        printf 'fake open stderr should be suppressed\\n' >&2
        if [ -n "${CMUX_TEST_OPEN_ENV_LOG:-}" ]; then
          env | LC_ALL=C sort | grep '^CMUX_' > "$CMUX_TEST_OPEN_ENV_LOG" || :
        fi
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "$CMUX_TEST_OPEN_LOG"
        done
        exit 0
        """
    }

    private func readFakeOpenArguments(from url: URL) throws -> [String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return Array(contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .dropLast())
    }

    private func readFakeOpenEnvironment(from url: URL) throws -> [String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return Array(contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .dropLast())
    }

    private func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                handled.signal()
                return
            }
            defer {
                Darwin.close(clientFD)
                handled.signal()
            }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)

                while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                    pending.removeSubrange(0...newlineRange.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    state.append(line)
                    let response = handler(line) + "\n"
                    _ = response.withCString { ptr in
                        Darwin.write(clientFD, ptr, strlen(ptr))
                    }
                }
            }
        }
        return handled
    }

    private static func v2Payload(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private static func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
}
