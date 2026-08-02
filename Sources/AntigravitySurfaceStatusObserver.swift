import CmuxAgentChat
import Foundation

/// Publishes Antigravity CLI turn status onto the surfaces running it.
///
/// Every other supported agent reports status through hooks, and failing that
/// through a transcript cmux can tail. Antigravity has neither lane on a stock
/// install: it exposes no resolvable transcript path and no stable session id
/// to the process table, so both of cmux's existing status sources are blind to
/// it and its tabs stayed permanently statusless.
///
/// Agent Studio solves this by reading Antigravity's own TUI, and this is the
/// same trick: find the surfaces whose foreground process is Antigravity, look
/// at what its interface is currently drawing, and translate that into the
/// panel's agent lifecycle — which the sidebar spinner and the tab-title
/// Running/Done marker already render.
///
/// Writes live under their own lifecycle key, so a user who *does* install the
/// Antigravity hooks keeps hook-driven status and this observer only ever adds
/// a second, agreeing opinion.
@MainActor
final class AntigravitySurfaceStatusObserver {
    static let shared = AntigravitySurfaceStatusObserver()

    /// Lifecycle key this observer owns. Namespaced away from the hook key
    /// (`antigravity`) so the two writers never clobber each other.
    static let lifecycleKey = "antigravity.tui"

    /// Agent definition id from ``CmuxTaskManagerCodingAgentDefinition``.
    private static let agentDefinitionID = "antigravity"

    /// Sampling period. Slow enough that the screen read stays off the typing
    /// path, fast enough that a finished turn flips to `✅` while the user is
    /// still looking at the tab.
    private static let sampleInterval: Duration = .seconds(2)

    /// How stale a shared process snapshot may be before this observer forces a
    /// fresh capture. Matched to ``sampleInterval`` so a tick reuses the sweep's
    /// snapshot when one just landed instead of scanning the process table twice.
    private static let snapshotMaximumAge: TimeInterval = 2

    private var task: Task<Void, Never>?
    /// Panels this observer currently owns a lifecycle entry on, so a surface
    /// that stops running Antigravity gets its marker cleared instead of
    /// keeping the last status forever.
    private var trackedPanelIds: Set<UUID> = []

    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleOnce()
                try? await Task.sleep(for: Self.sampleInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func sampleOnce() async {
        let surfaces = await Task.detached(priority: .utility) {
            Self.antigravitySurfaces()
        }.value
        apply(surfaces: surfaces)
    }

    /// `(workspaceId, panelId)` for every cmux surface whose foreground process
    /// group is Antigravity.
    private nonisolated static func antigravitySurfaces() -> [(workspaceId: UUID, panelId: UUID)] {
        let snapshot = CmuxTopProcessSnapshot.captureCached(
            includeProcessDetails: true,
            includeCMUXScope: true,
            maximumAge: snapshotMaximumAge
        )
        var seenPanelIds = Set<UUID>()
        var result: [(workspaceId: UUID, panelId: UUID)] = []
        for process in snapshot.cmuxScopedProcesses() {
            guard process.isTerminalForegroundProcessGroup,
                  let panelId = process.cmuxSurfaceID,
                  let workspaceId = process.cmuxWorkspaceID,
                  !seenPanelIds.contains(panelId) else { continue }
            let definition = AgentChatSessionRegistry.codingAgentDefinition(
                for: process,
                allowLaunchKindEnvironment: true,
                processArgumentsAndEnvironment: {
                    CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
                }
            )
            guard definition?.id == agentDefinitionID else { continue }
            seenPanelIds.insert(panelId)
            result.append((workspaceId, panelId))
        }
        return result
    }

    private func apply(surfaces: [(workspaceId: UUID, panelId: UUID)]) {
        var stillTracked: Set<UUID> = []
        for surface in surfaces {
            guard let workspace = AppDelegate.shared?.workspaceFor(tabId: surface.workspaceId),
                  let rows = Self.screenRows(surfaceID: surface.panelId) else { continue }
            stillTracked.insert(surface.panelId)
            switch AntigravityLiveScreenState.classify(screenRows: rows) {
            case .busy:
                workspace.setAgentLifecycle(
                    key: Self.lifecycleKey, panelId: surface.panelId, lifecycle: .running
                )
            case .idle:
                workspace.setAgentLifecycle(
                    key: Self.lifecycleKey, panelId: surface.panelId, lifecycle: .idle
                )
            case .unknown:
                // The screen is mid-scroll or showing a pager: keep whatever the
                // last confident sample decided rather than flapping the tab.
                if workspace.agentLifecycleStatesByPanelId[surface.panelId]?[Self.lifecycleKey] == nil {
                    workspace.setAgentLifecycle(
                        key: Self.lifecycleKey, panelId: surface.panelId, lifecycle: .idle
                    )
                }
            }
        }
        for panelId in trackedPanelIds.subtracting(stillTracked) {
            clearLifecycle(panelId: panelId)
        }
        trackedPanelIds = stillTracked
    }

    /// Drops this observer's entry from whichever workspace owns `panelId`.
    /// The panel's workspace is not re-derivable once the process is gone, so
    /// every workspace is asked to clear the key for that panel; the call is a
    /// no-op where no entry exists.
    private func clearLifecycle(panelId: UUID) {
        let managers = AppDelegate.shared?.recoverableMainWindowRoutes().compactMap(\.tabManager) ?? []
        for manager in managers {
            for workspace in manager.tabs {
                workspace.clearAgentLifecycle(key: Self.lifecycleKey, panelId: panelId)
            }
        }
    }

    /// Rendered screen rows for a surface (top to bottom), or `nil` when the
    /// surface has no live terminal.
    private static func screenRows(surfaceID: UUID) -> [String]? {
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) else {
            return nil
        }
        return surface.mobileRenderGridFrame(stateSeq: 0, full: true, includeTheme: false)?.rows
    }
}
