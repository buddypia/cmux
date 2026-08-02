import SwiftUI

struct AgentSessionWebRenderer: View {
    // Internal, not public: `AgentSessionPanel` is an app-target type, so a
    // public interface here cannot be satisfied and nothing outside the app
    // target can reach this view anyway.
    let panel: AgentSessionPanel

    init(panel: AgentSessionPanel) {
        self.panel = panel
    }

    var body: some View {
        AgentStudioSpriteView(scene: panel.scene)
    }

}
