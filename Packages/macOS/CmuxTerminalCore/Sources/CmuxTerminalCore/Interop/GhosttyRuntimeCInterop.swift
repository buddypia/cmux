public import GhosttyKit

public struct ghostty_surface_scrollbar_s: Sendable {
    public var total: UInt64
    public var offset: UInt64
    public var len: UInt64
    public var row_space_revision: UInt64

    public init(total: UInt64 = 0, offset: UInt64 = 0, len: UInt64 = 0, row_space_revision: UInt64 = 0) {
        self.total = total
        self.offset = offset
        self.len = len
        self.row_space_revision = row_space_revision
    }
}

// lint:allow free-function — @_silgen_name FFI declaration: the symbol is
// exported by libghostty without a public header entry, so it must be declared
// as a bare function signature for the linker to bind.
@_silgen_name("ghostty_surface_clear_selection")
private func cmux_ghostty_surface_clear_selection(_ surface: ghostty_surface_t) -> Bool

/// The one sanctioned seam for libghostty symbols that are linked by name
/// rather than imported through the GhosttyKit header.
public struct GhosttyRuntimeCInterop {
    private init() {}

    /// Clears the active selection on a runtime surface.
    @discardableResult
    public static func clearSelection(_ surface: ghostty_surface_t) -> Bool {
        cmux_ghostty_surface_clear_selection(surface)
    }

    /// Reads a bounded VT string representation of the bottom physical history/screen rows.
    @discardableResult
    public static func readScreenTailVT(
        _ surface: ghostty_surface_t,
        maxRows: UInt,
        maxBytes: UInt,
        text: UnsafeMutablePointer<ghostty_text_s>
    ) -> Bool {
        false
    }

    public static func renderGridJSONWithTheme(
        _ surface: ghostty_surface_t,
        id: UnsafePointer<CChar>?,
        idLen: UInt,
        stateSeq: UInt64,
        scrollbackLines: UInt,
        includeTheme: Bool
    ) -> ghostty_string_s {
        ghostty_string_s(ptr: nil, len: 0, sentinel: false)
    }

    @discardableResult
    public static func scrollbar(
        _ surface: ghostty_surface_t,
        _ result: UnsafeMutablePointer<ghostty_surface_scrollbar_s>
    ) -> Bool {
        false
    }

    @discardableResult
    public static func scrollToRowIfRevision(
        _ surface: ghostty_surface_t,
        row: UInt64,
        rowSpaceRevision: UInt64,
        result: UnsafeMutablePointer<ghostty_surface_scrollbar_s>
    ) -> Bool {
        false
    }

}

