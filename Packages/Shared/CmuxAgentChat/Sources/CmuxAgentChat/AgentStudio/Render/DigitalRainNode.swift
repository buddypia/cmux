import SpriteKit
import CoreGraphics

/// Node rendering matrix digital green text rain cascade overlays during agent coding and reading operations.
@MainActor
public class DigitalRainNode: SKNode {

    public let columnsCount: Int
    public let rainWidth: CGFloat
    public let rainHeight: CGFloat

    public private(set) var isActive: Bool = false
    private let rainContainer: SKNode = SKNode()

    private let matrixChars = Array("0123456789ABCDEF⌘⌥⇧⌃λµπ#%&*+-/<>=")

    public init(
        columnsCount: Int = 8,
        rainWidth: CGFloat = 120,
        rainHeight: CGFloat = 140
    ) {
        self.columnsCount = columnsCount
        self.rainWidth = rainWidth
        self.rainHeight = rainHeight
        super.init()

        self.zPosition = 50
        addChild(rainContainer)
    }

    required init?(coder aDecoder: NSCoder) {
        self.columnsCount = 8
        self.rainWidth = 120
        self.rainHeight = 140
        super.init(coder: aDecoder)

        addChild(rainContainer)
    }

    // MARK: - Rain Control

    /// Start cascading matrix green digital rain effect.
    public func startRain() {
        guard !isActive else { return }
        isActive = true

        rainContainer.removeAllChildren()
        rainContainer.alpha = 1.0

        let columnSpacing = rainWidth / CGFloat(columnsCount)
        let startX = -rainWidth * 0.5 + columnSpacing * 0.5

        for col in 0..<columnsCount {
            let x = startX + CGFloat(col) * columnSpacing
            spawnRainColumn(atX: x, colIndex: col)
        }
    }

    /// Stop matrix rain with smooth fade out.
    public func stopRain(fadeDuration: TimeInterval = 0.4) {
        guard isActive else { return }
        isActive = false

        rainContainer.removeAllActions()
        let fadeOut = SKAction.fadeOut(withDuration: fadeDuration)
        rainContainer.run(fadeOut) { [weak self] in
            self?.rainContainer.removeAllChildren()
        }
    }

    // MARK: - Private Column Spawning

    private func spawnRainColumn(atX x: CGFloat, colIndex: Int) {
        let charCount = Int.random(in: 4...8)
        let columnNode = SKNode()
        columnNode.position = CGPoint(x: x, y: rainHeight * 0.5 + CGFloat.random(in: 0...40))
        rainContainer.addChild(columnNode)

        for i in 0..<charCount {
            let label = SKLabelNode(fontNamed: "Courier-Bold")
            label.fontSize = 11
            let randomChar = String(matrixChars.randomElement() ?? "0")
            label.text = randomChar

            if i == 0 {
                // Leading drop is bright cyan-green
                label.fontColor = SKColor(red: 0.8, green: 1.0, blue: 0.8, alpha: 1.0)
            } else {
                // Trailing drops are matrix green with gradient opacity
                let opacity = CGFloat(charCount - i) / CGFloat(charCount)
                label.fontColor = SKColor(red: 0.0, green: 0.9, blue: 0.3, alpha: opacity)
            }

            label.position = CGPoint(x: 0, y: -CGFloat(i) * 14)
            columnNode.addChild(label)
        }

        let fallSpeed = CGFloat.random(in: 80...160)
        let distance = rainHeight + CGFloat(charCount * 14) + 40
        let duration = TimeInterval(distance / fallSpeed)

        let fallAction = SKAction.moveBy(x: 0, y: -distance, duration: duration)
        let removeAction = SKAction.run { [weak self, weak columnNode] in
            columnNode?.removeFromParent()
            if self?.isActive == true {
                self?.spawnRainColumn(atX: x, colIndex: colIndex)
            }
        }

        columnNode.run(SKAction.sequence([fallAction, removeAction]))
    }
}
