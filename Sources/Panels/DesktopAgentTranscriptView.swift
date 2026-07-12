import CmuxAgentChat
import CmuxAgentChatUI
import SwiftUI

/// A read-only, scrollable native transcript panel for the desktop app.
///
/// Reuses the shared ``ChatConversationStore`` and the `CmuxAgentChatUI` row
/// views so Codex / Antigravity / Claude sessions all render as a clean chat
/// thread instead of raw terminal scrollback. The panel follows the live tail
/// only while the user is already at the bottom (``TranscriptFollowLogic``):
/// scrolling up to review earlier turns is never interrupted by new output, and
/// a scroll-to-bottom pill re-engages following.
///
/// The follow decision uses macOS 14-compatible scroll geometry (a
/// ``GeometryReader`` reporting content height and offset through a preference)
/// rather than the iOS 18 scroll APIs the mobile transcript relies on.
struct DesktopAgentTranscriptView: View {
    @State private var store: ChatConversationStore
    @State private var expandedRowIDs: Set<String> = []
    @State private var isAtBottom = true
    @State private var viewportHeight: CGFloat = 0

    private let openTerminal: () -> Void

    /// Creates the transcript panel for one session.
    ///
    /// - Parameters:
    ///   - descriptor: Identity and header state of the session to show.
    ///   - source: The read-only conversation seam (e.g. a
    ///     `DesktopChatEventSource` tailing the live transcript).
    ///   - openTerminal: Escape hatch to focus the session's raw terminal.
    init(
        descriptor: ChatSessionDescriptor,
        source: any ChatEventSource,
        openTerminal: @escaping () -> Void = {}
    ) {
        _store = State(initialValue: ChatConversationStore(descriptor: descriptor, source: source))
        self.openTerminal = openTerminal
    }

    var body: some View {
        let actions = ChatRowActions(
            toggleExpanded: { id in
                if expandedRowIDs.contains(id) {
                    expandedRowIDs.remove(id)
                } else {
                    expandedRowIDs.insert(id)
                }
            },
            openTerminal: openTerminal
        )

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.hasMoreHistory {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .onAppear { Task { await store.loadOlder() } }
                    }
                    if store.rows.isEmpty {
                        placeholder
                    }
                    ForEach(store.rows) { row in
                        ChatTranscriptRowView(
                            row: row,
                            isExpanded: expandedRowIDs.contains(row.id),
                            actions: actions
                        )
                        .equatable()
                        .id(row.id)
                    }
                    // Stable trailing anchor: the scroll target for tail-follow
                    // and the pill, owning the final bottom breathing room so a
                    // scrollTo lands at the true content end.
                    Color.clear
                        .frame(height: 8)
                        .id(Self.bottomAnchorID)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    GeometryReader { contentGeo in
                        Color.clear.preference(
                            key: TranscriptOffsetKey.self,
                            value: TranscriptOffset(
                                contentHeight: contentGeo.size.height,
                                minY: contentGeo.frame(in: .named(Self.scrollSpace)).minY
                            )
                        )
                    }
                )
            }
            .coordinateSpace(.named(Self.scrollSpace))
            .background(
                GeometryReader { viewportGeo in
                    Color.clear
                        .onChange(of: viewportGeo.size.height, initial: true) { _, height in
                            viewportHeight = height
                        }
                }
            )
            .onPreferenceChange(TranscriptOffsetKey.self) { offset in
                isAtBottom = TranscriptFollowLogic.isAtBottom(
                    contentHeight: offset.contentHeight,
                    viewportHeight: viewportHeight,
                    scrollOffsetY: -offset.minY
                )
            }
            .onChange(of: store.rows) { _, _ in
                guard TranscriptFollowLogic.shouldAutoFollow(wasAtBottom: isAtBottom) else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    ChatScrollToBottomButton {
                        isAtBottom = true
                        withAnimation(.snappy(duration: 0.2)) {
                            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        }
                    }
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.snappy(duration: 0.2), value: isAtBottom)
        }
        .task { await store.run() }
    }

    @ViewBuilder
    private var placeholder: some View {
        if store.initialLoadFailed {
            VStack(spacing: 10) {
                Text("Couldn't load this conversation")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Retry") { Task { await store.retryInitialLoad() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else if store.hasLoadedInitialHistory {
            Text("No messages yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        } else {
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        }
    }

    private static let scrollSpace = "cmux.desktopTranscript.scroll"
    private static let bottomAnchorID = "cmux.desktopTranscript.bottom"
}

/// Content height and top-offset of the transcript within the scroll viewport,
/// carried out of the content ``GeometryReader`` for the at-bottom decision.
private struct TranscriptOffset: Equatable {
    var contentHeight: CGFloat
    var minY: CGFloat
}

private struct TranscriptOffsetKey: PreferenceKey {
    static let defaultValue = TranscriptOffset(contentHeight: 0, minY: 0)

    static func reduce(value: inout TranscriptOffset, nextValue: () -> TranscriptOffset) {
        value = nextValue()
    }
}
