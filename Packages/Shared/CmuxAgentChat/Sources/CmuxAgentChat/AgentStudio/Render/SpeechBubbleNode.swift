import SpriteKit
import CoreGraphics

/// Node rendering speech, thought, approval, error, and done status bubbles above character sprites.
@MainActor
public class SpeechBubbleNode: SKNode {

    /// Types of status speech bubbles displayed above characters.
    public enum BubbleType: Equatable, Sendable {
        case thinking
        case needsApproval
        case error
        case done
        case custom(String)
    }

    public private(set) var currentType: BubbleType?
    public private(set) var isVisible: Bool = false

    private let bubbleSprite: SKSpriteNode
    private let labelNode: SKLabelNode

    public init(type: BubbleType = .thinking) {
        let texture = PixelArtTextureFactory.shared.bubbleTexture(style: "default")
        self.bubbleSprite = SKSpriteNode(texture: texture, size: CGSize(width: 56, height: 38))
        self.labelNode = SKLabelNode(fontNamed: "Courier-Bold")

        super.init()

        self.zPosition = 40
        self.alpha = 0
        self.setScale(0.1)

        bubbleSprite.position = CGPoint(x: 0, y: 0)
        addChild(bubbleSprite)

        labelNode.fontSize = 12
        labelNode.fontColor = .black
        labelNode.verticalAlignmentMode = .center
        labelNode.horizontalAlignmentMode = .center
        labelNode.position = CGPoint(x: 0, y: 4)
        addChild(labelNode)

        updateType(type)
    }

    required init?(coder aDecoder: NSCoder) {
        let texture = PixelArtTextureFactory.shared.bubbleTexture(style: "default")
        self.bubbleSprite = SKSpriteNode(texture: texture, size: CGSize(width: 56, height: 38))
        self.labelNode = SKLabelNode(fontNamed: "Courier-Bold")
        super.init(coder: aDecoder)

        addChild(bubbleSprite)
        addChild(labelNode)
    }

    // MARK: - Display Control

    /// Update bubble type and label text content.
    public func updateType(_ type: BubbleType, text: String? = nil) {
        self.currentType = type

        let displayText: String
        let textColor: SKColor

        if let customText = text, !customText.isEmpty {
            displayText = customText
            textColor = .black
        } else {
            switch type {
            case .thinking:
                displayText = "..."
                textColor = .darkGray
            case .needsApproval:
                displayText = "APPROVE?"
                textColor = SKColor(red: 0.9, green: 0.5, blue: 0.0, alpha: 1.0)
            case .error:
                displayText = "ERROR!"
                textColor = SKColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1.0)
            case .done:
                displayText = "DONE ✓"
                textColor = SKColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 1.0)
            case .custom(let val):
                displayText = val
                textColor = .black
            }
        }

        labelNode.text = displayText
        labelNode.fontColor = textColor
    }

    /// Animate pop-in of speech bubble above character.
    public func show(type: BubbleType, text: String? = nil) {
        updateType(type, text: text)
        isVisible = true

        removeAllActions()

        let scaleUp = SKAction.scale(to: 1.0, duration: 0.2)
        scaleUp.timingMode = .easeOut
        let fadeIn = SKAction.fadeIn(withDuration: 0.15)
        let group = SKAction.group([scaleUp, fadeIn])

        run(group)

        // Pulsing animation for needsApproval
        if type == .needsApproval {
            let pulseOut = SKAction.scale(to: 1.1, duration: 0.4)
            let pulseIn = SKAction.scale(to: 1.0, duration: 0.4)
            let pulseSeq = SKAction.sequence([pulseOut, pulseIn])
            let repeatPulse = SKAction.repeatForever(pulseSeq)
            run(SKAction.sequence([group, repeatPulse]))
        }
    }

    /// Animate pop-out and hide of speech bubble.
    public func hide(completion: (() -> Void)? = nil) {
        guard isVisible else {
            completion?()
            return
        }

        isVisible = false
        removeAllActions()

        let scaleDown = SKAction.scale(to: 0.1, duration: 0.15)
        scaleDown.timingMode = .easeIn
        let fadeOut = SKAction.fadeOut(withDuration: 0.15)
        let group = SKAction.group([scaleDown, fadeOut])

        if scene == nil {
            self.alpha = 0
            self.setScale(0.1)
            completion?()
        } else {
            run(group) {
                completion?()
            }
        }
    }
}
