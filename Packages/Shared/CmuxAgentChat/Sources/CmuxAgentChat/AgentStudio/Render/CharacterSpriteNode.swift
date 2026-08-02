import SpriteKit
import CoreGraphics

/// Node representing an agent character sprite with 4-directional animations and FSM state synchronization.
@MainActor
public class CharacterSpriteNode: SKSpriteNode {

    public typealias Direction = PixelArtTextureFactory.Direction
    public typealias ActionState = PixelArtTextureFactory.ActionState

    public let agentId: String
    public let characterId: String

    public private(set) var currentState: AgentState = .idle
    public private(set) var currentDirection: Direction = .down

    /// Attached speech bubble node positioned above character's head.
    public let speechBubbleNode: SpeechBubbleNode

    /// Attached digital matrix rain node overlay.
    public let digitalRainNode: DigitalRainNode

    /// Home seat position where agent sits at desk.
    public var homeSeatPosition: CGPoint = .zero

    /// Home desk position facing computer.
    public var homeDeskPosition: CGPoint = .zero

    private let walkActionKey = "characterWalkAction"
    private let actionAnimKey = "characterAnimAction"

    public init(
        agentId: String,
        characterId: String = "char_0",
        position: CGPoint = .zero,
        size: CGSize = CGSize(width: 32, height: 32)
    ) {
        self.agentId = agentId
        self.characterId = characterId
        self.speechBubbleNode = SpeechBubbleNode(type: .thinking)
        self.digitalRainNode = DigitalRainNode(columnsCount: 6, rainWidth: 80, rainHeight: 100)

        let initialTexture = PixelArtTextureFactory.shared.characterTexture(
            characterId: characterId,
            direction: .down,
            action: .idle,
            frame: 0
        )

        super.init(texture: initialTexture, color: .clear, size: size)

        self.position = position
        self.homeSeatPosition = position
        self.homeDeskPosition = CGPoint(x: position.x, y: position.y + 20)
        self.zPosition = 30

        // Attach speech bubble above character head
        speechBubbleNode.position = CGPoint(x: 0, y: size.height * 0.75 + 16)
        addChild(speechBubbleNode)

        // Attach digital rain slightly above desk/character
        digitalRainNode.position = CGPoint(x: 0, y: size.height * 0.5 + 40)
        addChild(digitalRainNode)
    }

    required init?(coder aDecoder: NSCoder) {
        self.agentId = "unknown"
        self.characterId = "char_0"
        self.speechBubbleNode = SpeechBubbleNode(type: .thinking)
        self.digitalRainNode = DigitalRainNode()
        super.init(coder: aDecoder)

        addChild(speechBubbleNode)
        addChild(digitalRainNode)
    }

    // MARK: - FSM State Transition Binding

    /// Transition node visuals, animations, speech bubbles, and matrix rain directly based on ``AgentState``.
    public func transition(to newState: AgentState, message: String? = nil) {
        self.currentState = newState

        switch newState {
        case .idle:
            removeAction(forKey: walkActionKey)
            removeAction(forKey: actionAnimKey)
            digitalRainNode.stopRain()
            speechBubbleNode.hide()

            // Return to home seat facing front
            self.position = homeSeatPosition
            setDirection(.down, action: .idle)

        case .walk:
            removeAction(forKey: actionAnimKey)
            digitalRainNode.stopRain()
            speechBubbleNode.hide()
            startWalkAnimation(direction: currentDirection)

        case .activeRead:
            removeAction(forKey: walkActionKey)
            removeAction(forKey: actionAnimKey)
            digitalRainNode.stopRain()
            speechBubbleNode.hide()

            self.position = homeSeatPosition
            setDirection(.up, action: .read)
            startLoopingAnimation(action: .read)

        case .activeType:
            removeAction(forKey: walkActionKey)
            removeAction(forKey: actionAnimKey)

            self.position = homeSeatPosition
            setDirection(.up, action: .type)
            startLoopingAnimation(action: .type)

            // Trigger matrix digital rain cascade
            digitalRainNode.startRain()
            speechBubbleNode.hide()

        case .thinking:
            removeAction(forKey: walkActionKey)
            removeAction(forKey: actionAnimKey)
            digitalRainNode.stopRain()

            setDirection(.down, action: .thinking)
            speechBubbleNode.show(type: .thinking, text: message)

        case .needsApproval:
            removeAction(forKey: walkActionKey)
            removeAction(forKey: actionAnimKey)
            digitalRainNode.stopRain()

            setDirection(.down, action: .needsApproval)
            speechBubbleNode.show(type: .needsApproval, text: message)

        case .error:
            removeAction(forKey: walkActionKey)
            removeAction(forKey: actionAnimKey)
            digitalRainNode.stopRain()

            setDirection(.down, action: .error)
            speechBubbleNode.show(type: .error, text: message)

        case .done:
            removeAction(forKey: walkActionKey)
            removeAction(forKey: actionAnimKey)
            digitalRainNode.stopRain()

            setDirection(.down, action: .done)
            speechBubbleNode.show(type: .done, text: message)
        }
    }

    // MARK: - Direct Movement & Animations

    /// Perform a 4-directional walk movement to a target position using `SKAction.move`.
    public func walk(
        to target: CGPoint,
        duration: TimeInterval = 1.0,
        completion: (() -> Void)? = nil
    ) {
        let deltaX = target.x - position.x
        let deltaY = target.y - position.y

        let newDirection: Direction
        if abs(deltaX) > abs(deltaY) {
            newDirection = (deltaX > 0) ? .right : .left
        } else {
            newDirection = (deltaY > 0) ? .up : .down
        }

        self.currentDirection = newDirection
        transition(to: .walk)

        let moveAction = SKAction.move(to: target, duration: duration)
        let finishAction = SKAction.run { [weak self] in
            guard let self = self else { return }
            self.removeAction(forKey: self.walkActionKey)
            self.transition(to: .idle)
            completion?()
        }

        run(SKAction.sequence([moveAction, finishAction]))
    }

    /// Explicitly set character facing direction and action texture frame.
    public func setDirection(_ direction: Direction, action: ActionState = .idle) {
        self.currentDirection = direction
        let tex = PixelArtTextureFactory.shared.characterTexture(
            characterId: characterId,
            direction: direction,
            action: action,
            frame: 0
        )
        self.texture = tex
        self.texture?.filteringMode = .nearest
    }

    // MARK: - Private Animation Helpers

    private func startWalkAnimation(direction: Direction) {
        let frame0 = PixelArtTextureFactory.shared.characterTexture(
            characterId: characterId, direction: direction, action: .walk, frame: 0
        )
        let frame1 = PixelArtTextureFactory.shared.characterTexture(
            characterId: characterId, direction: direction, action: .walk, frame: 1
        )

        let animate = SKAction.animate(with: [frame0, frame1], timePerFrame: 0.2)
        let repeatWalk = SKAction.repeatForever(animate)
        run(repeatWalk, withKey: walkActionKey)
    }

    private func startLoopingAnimation(action: ActionState) {
        let frame0 = PixelArtTextureFactory.shared.characterTexture(
            characterId: characterId, direction: currentDirection, action: action, frame: 0
        )
        let frame1 = PixelArtTextureFactory.shared.characterTexture(
            characterId: characterId, direction: currentDirection, action: action, frame: 1
        )

        let animate = SKAction.animate(with: [frame0, frame1], timePerFrame: 0.3)
        let repeatAnim = SKAction.repeatForever(animate)
        run(repeatAnim, withKey: actionAnimKey)
    }
}
