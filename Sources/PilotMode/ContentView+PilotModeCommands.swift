import AppKit
import CmuxCommandPalette
import Foundation

/// Command palette entry points for the per-tab Pilot Mode override.
///
/// cmux runs many agents side by side, and a scratch tab and a release tab do
/// not deserve the same delegation policy — but the override is worthless
/// without a way to reach it, so it lives here rather than only in the
/// resolver. Both commands go through ``PilotModeSettingsStore/shared``, the
/// same path Settings, `cmux.json`, and `cmux pilot` use.
extension ContentView {
    func appendPilotModeCommandContributions(
        to contributions: inout [CommandPaletteCommandContribution]
    ) {
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: PilotModeTabCommands.toggleCommandId,
                title: { [self] _ in
                    let format = pilotModeEnabledForFocusedTab()
                        ? String(localized: "command.toggleSetting.disableTitle", defaultValue: "Disable %@")
                        : String(localized: "command.toggleSetting.enableTitle", defaultValue: "Enable %@")
                    return String.localizedStringWithFormat(
                        format,
                        String(
                            localized: "command.pilotModeForTab.title",
                            defaultValue: "Pilot Mode for This Tab"
                        )
                    )
                },
                subtitle: { [self] _ in pilotModeFocusedTabSubtitle() },
                keywords: [
                    "pilot", "mode", "tab", "surface", "this", "autopilot",
                    "auto", "approve", "approval", "unattended", "override",
                ],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )

        // Without this, a tab that has been toggled once can never go back to
        // following the global default.
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: PilotModeTabCommands.clearOverrideCommandId,
                title: { _ in
                    String(
                        localized: "command.clearPilotModeTabOverride.title",
                        defaultValue: "Use the Default Pilot Mode for This Tab"
                    )
                },
                subtitle: { [self] _ in pilotModeFocusedTabSubtitle() },
                keywords: [
                    "pilot", "mode", "tab", "surface", "default", "clear",
                    "reset", "override", "inherit",
                ],
                when: { [self] snapshot in
                    guard snapshot.bool(CommandPaletteContextKeys.hasFocusedPanel) else { return false }
                    return pilotModeFocusedTabHasOverride()
                }
            )
        )
    }

    func registerPilotModeCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: PilotModeTabCommands.toggleCommandId) {
            guard let surfaceId = focusedPanelContext?.panelId else {
                NSSound.beep()
                return
            }
            PilotModeSettingsStore.shared.toggle(forSurface: surfaceId)
        }
        registry.register(commandId: PilotModeTabCommands.clearOverrideCommandId) {
            guard let surfaceId = focusedPanelContext?.panelId else {
                NSSound.beep()
                return
            }
            PilotModeSettingsStore.shared.setOverride(nil, forSurface: surfaceId)
        }
    }

    private func pilotModeEnabledForFocusedTab() -> Bool {
        PilotModeSettingsStore.shared.isEnabled(forSurface: focusedPanelContext?.panelId)
    }

    private func pilotModeFocusedTabHasOverride() -> Bool {
        guard let surfaceId = focusedPanelContext?.panelId else { return false }
        return PilotModeSettingsStore.shared.override(forSurface: surfaceId) != nil
    }

    /// Says both what the tab resolves to and *why* — an override reads
    /// differently from inheriting a global switch, and a user deciding whether
    /// to flip this tab needs to know which one they are looking at.
    private func pilotModeFocusedTabSubtitle() -> String {
        let state = pilotModeEnabledForFocusedTab()
            ? String(localized: "command.toggleSetting.state.on", defaultValue: "On")
            : String(localized: "command.toggleSetting.state.off", defaultValue: "Off")
        let format = pilotModeFocusedTabHasOverride()
            ? String(
                localized: "command.pilotModeForTab.subtitle.override",
                defaultValue: "This tab only • %@"
            )
            : String(
                localized: "command.pilotModeForTab.subtitle.inherited",
                defaultValue: "Following the default • %@"
            )
        return String.localizedStringWithFormat(format, state)
    }
}

enum PilotModeTabCommands {
    static let toggleCommandId = "palette.togglePilotModeForTab"
    static let clearOverrideCommandId = "palette.clearPilotModeTabOverride"
}
