import AppKit

@MainActor
public final class AgentSessionWebView: NSView {
    public var onPointerDown: (() -> Void)?

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    public override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        super.mouseDown(with: event)
    }
}
