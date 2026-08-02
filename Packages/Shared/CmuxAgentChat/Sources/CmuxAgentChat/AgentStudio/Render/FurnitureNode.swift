import SpriteKit
import CoreGraphics

/// Node representing an office furniture object (desk, computer PC, bookshelf, plant, chair, etc.).
@MainActor
public class FurnitureNode: SKSpriteNode {

    /// Categories of office furniture supported in Agent Studio.
    public enum FurnitureCategory: String, CaseIterable, Sendable {
        case desk = "DESK"
        case pc = "PC"
        case bookshelf = "BOOKSHELF"
        case sofa = "SOFA"
        case plant = "PLANT"
        case whiteboard = "WHITEBOARD"
        case chair = "CUSHIONED_CHAIR"
        case coffeeTable = "COFFEE_TABLE"
    }

    /// Monitor screen state for PC furniture nodes.
    public enum PCState: String, CaseIterable, Sendable {
        case off
        case screen1
        case screen2
        case screen3
    }

    public let category: FurnitureCategory
    public private(set) var variant: String
    public private(set) var pcState: PCState = .off

    private let pcAnimationKey = "pcScreenAnimation"

    public init(
        category: FurnitureCategory,
        position: CGPoint,
        zPosition: CGFloat = 20,
        variant: String = "front",
        size: CGSize = CGSize(width: 48, height: 48)
    ) {
        self.category = category
        self.variant = variant

        let texture = PixelArtTextureFactory.shared.furnitureTexture(
            category: category.rawValue,
            variant: variant,
            frame: 0
        )

        super.init(texture: texture, color: .clear, size: size)

        self.position = position
        self.zPosition = zPosition
    }

    required init?(coder aDecoder: NSCoder) {
        self.category = .desk
        self.variant = "front"
        super.init(coder: aDecoder)
    }

    // MARK: - State & Screen Animation

    /// Set PC monitor screen state (off, screen1, screen2, screen3).
    public func setPCState(_ state: PCState) {
        guard category == .pc else { return }
        self.pcState = state
        removeAction(forKey: pcAnimationKey)

        let variantName = (state == .off) ? "off" : "on"
        let frameIndex: Int
        switch state {
        case .off: frameIndex = 0
        case .screen1: frameIndex = 0
        case .screen2: frameIndex = 1
        case .screen3: frameIndex = 2
        }

        self.texture = PixelArtTextureFactory.shared.furnitureTexture(
            category: category.rawValue,
            variant: variantName,
            frame: frameIndex
        )
        self.texture?.filteringMode = .nearest
    }

    /// Animate PC monitor code screens while character is actively typing.
    public func animatePCScreen(isTyping: Bool) {
        guard category == .pc else { return }
        removeAction(forKey: pcAnimationKey)

        if !isTyping {
            setPCState(.off)
            return
        }

        let textures: [SKTexture] = [
            PixelArtTextureFactory.shared.furnitureTexture(category: category.rawValue, variant: "on", frame: 0),
            PixelArtTextureFactory.shared.furnitureTexture(category: category.rawValue, variant: "on", frame: 1),
            PixelArtTextureFactory.shared.furnitureTexture(category: category.rawValue, variant: "on", frame: 2)
        ]

        let animateAction = SKAction.animate(with: textures, timePerFrame: 0.25)
        let repeatAction = SKAction.repeatForever(animateAction)
        run(repeatAction, withKey: pcAnimationKey)
    }
}
