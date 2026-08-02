import SwiftUI
import SpriteKit
import CmuxAgentChat

public struct AgentStudioSpriteView: NSViewRepresentable {
    public let scene: AgentStudioScene
    
    public init(scene: AgentStudioScene) {
        self.scene = scene
    }
    
    public func makeNSView(context: Context) -> SKView {
        let skView = SKView()
        skView.ignoresSiblingOrder = true
        skView.showsFPS = false
        skView.showsNodeCount = false
        skView.presentScene(scene)
        return skView
    }
    
    public func updateNSView(_ nsView: SKView, context: Context) {
        if nsView.scene != scene {
            nsView.presentScene(scene)
        }
    }
}
