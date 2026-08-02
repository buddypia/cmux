import AppKit
import CmuxSidebar
import Testing
@testable import cmux_DEV

/// Behavior tests for the pure-AppKit workspace row cell: hover enforcement
/// (authoritative sweep) and optimistic selection paint semantics.
@Suite
@MainActor
struct SidebarAppKitRowCellTests {
    private static func makeSnapshot(
        title: String = "Workspace",
        agentStatusGroups: [AgentStatusBadgeGroup] = []
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: SidebarWorkspaceSnapshotFactory.presentationKey(
                settings: SidebarTabItemSettingsSnapshot(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                showsAgentActivity: false
            ),
            title: title,
            customDescription: nil,
            isPinned: false,
            customColorHex: nil,
            remoteWorkspaceSidebarText: nil,
            remoteConnectionStatusText: "",
            remoteStateHelpText: "",
            showsRemoteReconnectAffordance: false,
            copyableSidebarSSHError: nil,
            latestConversationMessage: nil,
            metadataEntries: [],
            metadataBlocks: [],
            latestLog: nil,
            progress: nil,
            activeCodingAgentCount: 0,
            agentStatusGroups: agentStatusGroups,
            latestAgentOutput: nil,
            compactGitBranchSummaryText: nil,
            compactDirectoryCandidates: [],
            compactBranchDirectoryCandidates: [],
            branchDirectoryLines: [],
            branchLinesContainBranch: false,
            pullRequestRows: [],
            listeningPorts: [],
            finderDirectoryPath: nil,
            mediaActivity: BrowserMediaActivity(),
            taskStatus: nil,
            todoStatusMenuModel: nil,
            hasManualTaskStatus: false,
            checklistItems: [],
            checklistCompletedCount: 0,
            checklistTotalCount: 0,
            checklistFirstUncheckedText: nil
        )
    }

    private static func makeModel(
        workspaceId: UUID = UUID(),
        isActive: Bool = false,
        canClose: Bool = true,
        settings: SidebarTabItemSettingsSnapshot? = nil,
        snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot? = nil
    ) -> SidebarWorkspaceRowModel {
        let resolvedSettings = settings
            ?? SidebarTabItemSettingsSnapshot(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return SidebarWorkspaceRowModel(
            workspaceId: workspaceId,
            index: 0,
            snapshot: snapshot ?? makeSnapshot(),
            settings: resolvedSettings,
            isActive: isActive,
            isMultiSelected: false,
            canCloseWorkspace: canClose,
            accessibilityWorkspaceCount: 1,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: resolvedSettings.details.showAgentActivity,
            rowSpacing: 8,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: false,
            isFirstRow: true,
            shortcutHintText: nil,
            showsShortcutHints: false,
            colorSchemeIsDark: true,
            globalFontMagnificationPercent: 100,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isMetadataExpanded: false,
            isMarkdownExpanded: false
        )
    }

    private static func makeSwiftUIRow(
        settings: SidebarTabItemSettingsSnapshot
    ) -> SidebarWorkspaceRowSnapshot {
        SidebarWorkspaceRowSnapshot(
            workspaceId: UUID(),
            groupId: nil,
            index: 0,
            workspaceCount: 1,
            workspace: makeSnapshot(),
            isActive: false,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            hasCustomTitle: false,
            hasCustomDescription: false,
            customTitle: nil,
            workspaceShortcutDigit: nil,
            workspaceShortcutModifierSymbol: "⌘",
            canCloseWorkspace: true,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: settings.details.showAgentActivity,
            rowSpacing: 8,
            showsModifierShortcutHints: false,
            isPointerHovering: false,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isBonsplitWorkspaceDropActive: false,
            settings: settings,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            contextMenu: SidebarWorkspaceContextMenuSnapshot(
                targetWorkspaceIds: [],
                remoteTargetWorkspaceIds: [],
                allRemoteTargetsConnecting: false,
                allRemoteTargetsDisconnected: false,
                pinState: nil,
                groupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
                canCreateEmptyGroup: true,
                eligibleGroupTargetIds: [],
                allEligibleTargetsGroupId: nil,
                hasGroupedEligibleTarget: false,
                todoStatusLanes: [],
                canMarkRead: false,
                canMarkUnread: false,
                hasLatestNotification: false,
                notifications: []
            )
        )
    }

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SidebarAppKitRowCellTests.\(UUID().uuidString)")!
    }

    private static func makeActions(model: SidebarWorkspaceRowModel) -> SidebarAppKitRowActions {
        let commands = SidebarWorkspaceRowCommands(
            tab: Workspace(),
            tabManager: nil,
            notificationStore: nil,
            index: model.index,
            contextMenuWorkspaceIds: [model.workspaceId],
            remoteContextMenuWorkspaceIds: [],
            allRemoteContextMenuTargetsConnecting: false,
            allRemoteContextMenuTargetsDisconnected: false,
            contextMenuPinState: nil,
            workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            refreshSnapshot: {},
            readSelectedTabIds: { [] },
            writeSelectedTabIds: { _ in },
            readLastSelectionIndex: { nil },
            writeLastSelectionIndex: { _ in },
            setSelectionToTabs: {},
            snapshotProvider: { nil }
        )
        return SidebarAppKitRowActions(
            commands: commands,
            onOpenPullRequest: { _ in },
            onOpenPort: { _ in },
            onToggleChecklistExpansion: {},
            onToggleMetadataExpansion: {},
            onToggleMarkdownExpansion: {},
            onConsumeChecklistAddFieldActivation: {},
            checklistSetItemState: { _, _ in },
            checklistRemoveItem: { _ in },
            checklistAddItem: { _ in },
            checklistEditItem: { _, _ in },
            commitRename: { _ in }
        )
    }

    private static func configuredCell(
        model: SidebarWorkspaceRowModel
    ) -> SidebarWorkspaceRowTableCellView {
        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: model,
            actions: makeActions(model: model),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        return cell
    }

    /// A per-CLI pill carries a CLI name, so it can be wider than the row. The
    /// pill clips its own text but the row does not clip the pill, and the
    /// wrap rule cannot help the first pill on a line — without a clamp the
    /// badge paints over the row's trailing edge.
    @Test(arguments: [120.0, 240.0])
    func agentStatusPillsNeverPaintPastTheRowTrailingEdge(_ width: CGFloat) {
        let groups = AgentStatusBadgeSummary.cliGroups(from: [
            AgentSurfaceStatusSummary(status: .running, agentKey: "antigravity", isRestored: false, lastMessage: nil),
            AgentSurfaceStatusSummary(status: .done, agentKey: "antigravity", isRestored: false, lastMessage: nil),
            AgentSurfaceStatusSummary(status: .idle, agentKey: "hermes-agent", isRestored: false, lastMessage: nil),
        ])
        let model = Self.makeModel(snapshot: Self.makeSnapshot(agentStatusGroups: groups))
        let cell = Self.configuredCell(model: model)

        cell.layoutContent(model: model, width: width, apply: true)

        let trailing = width - SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
            - SidebarWorkspaceListMetrics.rowContentHorizontalPadding
        let pills = cell.subviews.compactMap { $0 as? SidebarRowAgentStatusPill }.filter { !$0.isHidden }
        #expect(pills.count == 2)
        for pill in pills {
            #expect(pill.frame.maxX <= trailing + 0.5)
        }
    }

    /// The strip is the row's answer to "which CLI, in what state" — it must
    /// draw one pill per CLI, not one merged count.
    @Test
    func agentStatusStripDrawsOnePillPerCLI() {
        let groups = AgentStatusBadgeSummary.cliGroups(from: [
            AgentSurfaceStatusSummary(status: .running, agentKey: "codex", isRestored: false, lastMessage: nil),
            AgentSurfaceStatusSummary(status: .done, agentKey: "codex", isRestored: false, lastMessage: nil),
            AgentSurfaceStatusSummary(status: .idle, agentKey: "claude_code", isRestored: false, lastMessage: nil),
        ])
        let model = Self.makeModel(snapshot: Self.makeSnapshot(agentStatusGroups: groups))
        let cell = Self.configuredCell(model: model)

        let pills = cell.subviews.compactMap { $0 as? SidebarRowAgentStatusPill }.filter { !$0.isHidden }
        #expect(pills.count == 2)
        // The tooltip is localized, so assert it names this pill's CLI rather
        // than pinning English wording that fails on a Japanese machine.
        #expect(pills.first?.toolTip?.hasPrefix("Codex ") == true)
    }

    @Test(arguments: zip(["codex", "claude_code"], ["Running", "Needs input"]))
    func metadataStatusTextOmitsRawAgentKey(_ key: String, _ status: String) throws {
        let model = Self.makeModel()
        let row = SidebarRowIconTextLine()

        row.configureMetadataEntry(
            SidebarStatusEntry(key: key, value: status, icon: "bolt.fill"),
            model: model,
            color: .labelColor
        )

        let textView = try #require(row.subviews.compactMap { $0 as? SidebarRowTextView }.first)
        #expect(textView.stringValue == status)
        #expect(!textView.stringValue.contains(key))
    }

    @Test
    func hoverEnforcementShortCircuitsWhenAlreadyCorrect() {
        let model = Self.makeModel()
        let cell = Self.configuredCell(model: model)
        var applies = 0
        cell.applyModelProbeForTesting = { _ in applies += 1 }

        cell.enforcePointerHovering(false)
        #expect(applies == 0)

        cell.enforcePointerHovering(true)
        #expect(applies == 1)

        cell.enforcePointerHovering(true)
        #expect(applies == 1)
    }

    @Test
    func optimisticSelectionPaintsFlippedModelButKeepsAuthoritativeState() {
        let model = Self.makeModel(isActive: false)
        let cell = Self.configuredCell(model: model)
        var appliedActive: [Bool] = []
        cell.applyModelProbeForTesting = { appliedActive.append($0.isActive) }

        cell.showOptimisticSelectionHighlight()
        // Full selected treatment painted from a flipped copy...
        #expect(appliedActive == [true])
        // ...while the stored model stays authoritative (not selected).
        #expect(cell.currentModelForMeasurement?.isActive == false)
    }

    @Test
    func optimisticDeselectionOnlyActsOnSelectedRows() {
        let inactive = Self.makeModel(isActive: false)
        let cell = Self.configuredCell(model: inactive)
        var applies = 0
        cell.applyModelProbeForTesting = { _ in applies += 1 }

        cell.showOptimisticDeselection()
        #expect(applies == 0)

        let active = Self.makeModel(isActive: true)
        let activeCell = Self.configuredCell(model: active)
        var activeApplied: [Bool] = []
        activeCell.applyModelProbeForTesting = { activeApplied.append($0.isActive) }
        activeCell.showOptimisticDeselection()
        #expect(activeApplied == [false])
        #expect(activeCell.currentModelForMeasurement?.isActive == true)
    }

    @Test
    func defaultSettingsResolveTheSameStackedVerticalBranchLayoutForBothRows() {
        let settings = SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults())
        let swiftUIRow = Self.makeSwiftUIRow(settings: settings)
        let appKitRow = Self.makeModel(settings: settings)

        #expect(settings.branchDirectory.branchLayout == .vertical)
        #expect(settings.branchDirectory.branchDirectoryPlacement == .stacked)
        #expect(!settings.branchDirectory.usesLastSegmentPath)
        #expect(!settings.wrapsWorkspaceTitles)
        #expect(swiftUIRow.settings.branchDirectory == settings.branchDirectory)
        #expect(appKitRow.settings.branchDirectory == settings.branchDirectory)
    }

    @Test(arguments: [false, true])
    func storedLegacyBranchLayoutControlsBothRows(_ usesVerticalLayout: Bool) {
        let defaults = Self.makeDefaults()
        defaults.set(usesVerticalLayout, forKey: "sidebarBranchVerticalLayout")
        defaults.set(false, forKey: "sidebarBranchDirectoryStacked")
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let expectedLayout: SidebarWorkspaceBranchDirectorySettings.BranchLayout = usesVerticalLayout
            ? .vertical
            : .inline
        let expectedPlacement: SidebarWorkspaceBranchDirectorySettings.BranchDirectoryPlacement = usesVerticalLayout
            ? .stacked
            : .inline

        #expect(settings.branchDirectory.branchLayout == expectedLayout)
        #expect(settings.branchDirectory.branchDirectoryPlacement == expectedPlacement)
        #expect(Self.makeSwiftUIRow(settings: settings).settings.branchDirectory == settings.branchDirectory)
        #expect(Self.makeModel(settings: settings).settings.branchDirectory == settings.branchDirectory)
    }

    @Test(arguments: [false, true])
    func storedBranchDirectoryPlacementRemainsAnIndependentSetting(_ stacks: Bool) {
        let defaults = Self.makeDefaults()
        defaults.set(false, forKey: "sidebarBranchVerticalLayout")
        defaults.set(stacks, forKey: "sidebarBranchDirectoryStacked")
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let expected: SidebarWorkspaceBranchDirectorySettings.BranchDirectoryPlacement = stacks
            ? .stacked
            : .inline

        #expect(settings.branchDirectory.branchLayout == .inline)
        #expect(settings.branchDirectory.branchDirectoryPlacement == expected)
        #expect(Self.makeSwiftUIRow(settings: settings).settings.branchDirectory == settings.branchDirectory)
        #expect(Self.makeModel(settings: settings).settings.branchDirectory == settings.branchDirectory)
    }

    @Test(arguments: [false, true])
    func storedPathAndTitlePreferencesAreSharedByBothRows(_ enabled: Bool) {
        let defaults = Self.makeDefaults()
        defaults.set(enabled, forKey: "sidebarPathLastSegmentOnly")
        defaults.set(enabled, forKey: SidebarWorkspaceTitleWrapSettings.key)
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let swiftUISettings = Self.makeSwiftUIRow(settings: settings).settings
        let appKitSettings = Self.makeModel(settings: settings).settings

        #expect(settings.branchDirectory.usesLastSegmentPath == enabled)
        #expect(settings.wrapsWorkspaceTitles == enabled)
        #expect(swiftUISettings.branchDirectory.usesLastSegmentPath == enabled)
        #expect(swiftUISettings.wrapsWorkspaceTitles == enabled)
        #expect(appKitSettings.branchDirectory.usesLastSegmentPath == enabled)
        #expect(appKitSettings.wrapsWorkspaceTitles == enabled)
    }

    @Test
    func everyWorkspaceDetailSettingUsesCatalogDefaultsInBothRows() {
        let settings = SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults())
        let swiftUIDetails = Self.makeSwiftUIRow(settings: settings).settings.details
        let appKitDetails = Self.makeModel(settings: settings).settings.details
        let keys: [KeyPath<SidebarWorkspaceDetailSettings, Bool>] = [
            \.showBranchDirectory,
            \.showPullRequests,
            \.watchGitStatus,
            \.showSSH,
            \.showPorts,
            \.showLog,
            \.showProgress,
            \.showAgentActivity,
            \.showCustomMetadata,
        ]

        for key in keys {
            #expect(settings.details[keyPath: key])
            #expect(swiftUIDetails[keyPath: key] == settings.details[keyPath: key])
            #expect(appKitDetails[keyPath: key] == settings.details[keyPath: key])
        }
    }

    @Test
    func everyStoredWorkspaceDetailPreferenceIsHonoredInBothRows() {
        let cases: [(String, KeyPath<SidebarWorkspaceDetailSettings, Bool>)] = [
            ("sidebarShowBranchDirectory", \.showBranchDirectory),
            ("sidebarShowPullRequest", \.showPullRequests),
            ("sidebarWatchGitStatus", \.watchGitStatus),
            ("sidebarShowSSH", \.showSSH),
            ("sidebarShowPorts", \.showPorts),
            ("sidebarShowLog", \.showLog),
            ("sidebarShowProgress", \.showProgress),
            ("sidebarShowAgentActivity", \.showAgentActivity),
            ("sidebarShowStatusPills", \.showCustomMetadata),
        ]

        for (defaultsKey, detailKey) in cases {
            let defaults = Self.makeDefaults()
            defaults.set(false, forKey: defaultsKey)
            let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)

            #expect(!settings.details[keyPath: detailKey])
            #expect(!Self.makeSwiftUIRow(settings: settings).settings.details[keyPath: detailKey])
            #expect(!Self.makeModel(settings: settings).settings.details[keyPath: detailKey])
        }
    }
}
