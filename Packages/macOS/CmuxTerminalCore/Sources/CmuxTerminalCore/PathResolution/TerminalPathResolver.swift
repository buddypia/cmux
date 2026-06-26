public import Foundation

/// Resolves file-system paths out of raw terminal text.
///
/// This is the shared path heuristics layer behind cmd-click QuickLook,
/// "open file at cursor", and terminal link opening. Candidate spellings come
/// from the pure `String` transforms in this domain (shell-token unquoting
/// and unescaping, trailing-punctuation trimming, visible-line
/// tokenization); the resolver expands them for `~`, resolves relative
/// candidates against the surface cwd, standardizes, and probes in order.
///
/// The resolver is an instantiated value because resolution is pure only up
/// to the file system: every resolve probes candidates for existence, so the
/// file-existence capability is injected at init. Production uses the real
/// file system; tests inject a fake probe. This mirrors
/// ``TerminalLinkRouter``'s injected `BrowserHostNormalizing` seam.
public struct TerminalVisibleTokenResolution: Equatable, Sendable {
    public let rawToken: String
    public let startRow: Int
    public let endRow: Int
}

public struct TerminalPathResolver: Sendable {
    private let fileExists: @Sendable (String) -> Bool

    private struct WrappedVisibleLine {
        let text: String
        let column: Int
        let startRow: Int
        let endRow: Int
    }

    /// Creates a resolver that probes candidate paths through `fileExists`.
    ///
    /// - Parameter fileExists: The file-existence capability; defaults to the
    ///   real file system.
    public init(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.fileExists = fileExists
    }

    /// Resolves raw terminal text to an existing file path for QuickLook.
    ///
    /// Candidates are derived from the raw text (as-is, shell-unescaped,
    /// shell-unquoted, and trailing-punctuation-trimmed variants), expanded
    /// for `~`, resolved against `cwd` when relative, standardized, and probed
    /// in order. The first existing path wins.
    ///
    /// - Parameters:
    ///   - rawText: The raw text under the cursor or selection.
    ///   - cwd: The surface's working directory used for relative candidates.
    /// - Returns: The first existing standardized path, or `nil`.
    public func resolveQuicklookPath(_ rawText: String, cwd: String?) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var seenPaths: Set<String> = []
        for token in trimmed.pathResolutionCandidates() {
            let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedToken.isEmpty else { continue }

            let expandedToken = (normalizedToken as NSString).expandingTildeInPath
            let candidatePath: String
            if expandedToken.hasPrefix("/") {
                candidatePath = expandedToken
            } else {
                guard let cwd, !cwd.isEmpty else { continue }
                candidatePath = (cwd as NSString).appendingPathComponent(expandedToken)
            }

            let standardizedPath = (candidatePath as NSString).standardizingPath
            guard seenPaths.insert(standardizedPath).inserted else { continue }
            if fileExists(standardizedPath) {
                return standardizedPath
            }
        }

        return nil
    }

    /// Resolves the path token under a column of a visible terminal line.
    ///
    /// Tries the raw whitespace-delimited segment around the column first,
    /// then the shell-escape-aware token, and resolves each through
    /// ``resolveQuicklookPath(_:cwd:)``.
    ///
    /// - Parameters:
    ///   - line: The visible line text.
    ///   - column: The zero-based column under the cursor.
    ///   - cwd: The surface's working directory.
    /// - Returns: The raw token plus its resolved path, or `nil`.
    public func resolveVisibleLinePath(
        _ line: String,
        column: Int,
        cwd: String
    ) -> (rawToken: String, path: String)? {
        for rawToken in line.pathTokenCandidates(containingColumn: column) {
            if let resolvedPath = resolveQuicklookPath(rawToken, cwd: cwd) {
                return (rawToken, resolvedPath)
            }
        }
        return nil
    }

    /// Returns token candidates around a visible terminal cell, expanding
    /// across adjacent soft-wrapped rows when the previous row fills the
    /// terminal width.
    ///
    /// Ghostty can report wrapped links one visual row at a time. This helper
    /// reconstructs the token from the visible viewport before URL/path routing
    /// so a click on either visual row sees the whole link.
    ///
    /// - Parameters:
    ///   - lines: Visible terminal rows, top to bottom.
    ///   - row: The zero-based visible row under the cursor.
    ///   - column: The zero-based terminal column under the cursor.
    ///   - columns: The terminal viewport width in columns.
    /// - Returns: Token candidates around the adjusted column.
    public func visibleWrappedTokenCandidates(
        _ lines: [String],
        row: Int,
        column: Int,
        columns: Int
    ) -> [TerminalVisibleTokenResolution] {
        guard let wrapped = Self.wrappedVisibleLine(
            lines,
            row: row,
            column: column,
            columns: columns
        ) else {
            return []
        }

        return wrapped.text.pathTokenCandidates(containingColumn: wrapped.column).map {
            TerminalVisibleTokenResolution(
                rawToken: $0,
                startRow: wrapped.startRow,
                endRow: wrapped.endRow
            )
        }
    }

    /// Resolves a file path under a visible terminal cell, including paths
    /// split across soft-wrapped visual rows.
    public func resolveVisibleWrappedLinePath(
        _ lines: [String],
        row: Int,
        column: Int,
        columns: Int,
        cwd: String
    ) -> (rawToken: String, path: String)? {
        for token in visibleWrappedTokenCandidates(lines, row: row, column: column, columns: columns) {
            if let resolvedPath = resolveQuicklookPath(token.rawToken, cwd: cwd) {
                return (token.rawToken, resolvedPath)
            }
        }
        return nil
    }

    /// Resolves an open-URL request payload to an existing file path.
    ///
    /// Text that parses as a URL with a scheme is never treated as a file
    /// path; everything else goes through ``resolveQuicklookPath(_:cwd:)``.
    ///
    /// - Parameters:
    ///   - rawText: The raw open-URL text from the runtime.
    ///   - cwd: The surface's working directory.
    /// - Returns: The first existing standardized path, or `nil`.
    public func resolveOpenURLFilePath(_ rawText: String, cwd: String?) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard URL(string: trimmed)?.scheme == nil else { return nil }
        return resolveQuicklookPath(trimmed, cwd: cwd)
    }

    private static func wrappedVisibleLine(
        _ lines: [String],
        row: Int,
        column: Int,
        columns: Int
    ) -> WrappedVisibleLine? {
        guard row >= 0, row < lines.count else { return nil }
        let currentLine = lines[row]
        guard !currentLine.isEmpty, column >= 0, column < currentLine.count else {
            return nil
        }

        let terminalColumns = max(columns, 1)
        var startRow = row
        while startRow > 0,
              softWraps(from: lines[startRow - 1], to: lines[startRow], columns: terminalColumns) {
            startRow -= 1
        }

        var endRow = row
        while endRow + 1 < lines.count,
              softWraps(from: lines[endRow], to: lines[endRow + 1], columns: terminalColumns) {
            endRow += 1
        }

        var adjustedColumn = column
        if startRow < row {
            adjustedColumn += lines[startRow..<row].reduce(0) { $0 + $1.count }
        }

        return WrappedVisibleLine(
            text: lines[startRow...endRow].joined(),
            column: adjustedColumn,
            startRow: startRow,
            endRow: endRow
        )
    }

    private static func softWraps(from previous: String, to next: String, columns: Int) -> Bool {
        guard previous.count >= columns,
              let previousLast = previous.last,
              let nextFirst = next.first else {
            return false
        }
        if previousLast.isWhitespace {
            return false
        }
        if nextFirst.isWhitespace, previousLast != "\\" {
            return false
        }
        return true
    }
}
