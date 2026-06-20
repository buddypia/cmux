import Foundation

public enum PilotTuiInspectionStatus: String, Sendable, Equatable, Codable {
    case menu
    case submitReady = "submit_ready"
    case noMenu = "no_menu"
}

public struct PilotTuiInspection: Sendable, Equatable, Codable {
    public let status: PilotTuiInspectionStatus
    public let menu: PilotTuiMenu?
    public let submitBar: PilotTuiSubmitBar?

    public init(
        status: PilotTuiInspectionStatus,
        menu: PilotTuiMenu?,
        submitBar: PilotTuiSubmitBar?
    ) {
        self.status = status
        self.menu = menu
        self.submitBar = submitBar
    }
}

public enum PilotTuiInspector {
    public static func inspect(screen: String) -> PilotTuiInspection {
        let menu = PilotTuiMenuParser.parseMenu(screen: screen)
        let submitBar = PilotTuiMenuParser.parseSubmitBar(screen: screen)
        let status: PilotTuiInspectionStatus
        if submitBar?.isReadyToSubmit == true {
            status = .submitReady
        } else if menu != nil {
            status = .menu
        } else {
            status = .noMenu
        }

        return PilotTuiInspection(
            status: status,
            menu: menu,
            submitBar: submitBar
        )
    }
}
