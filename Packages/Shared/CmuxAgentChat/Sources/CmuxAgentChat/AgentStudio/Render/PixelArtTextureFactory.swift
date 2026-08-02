import SpriteKit
import CoreGraphics

/// Utility for generating integer-scaled pixel-art `SKTexture` objects with `.nearest` filtering mode.
///
/// Ensures deterministic texture creation across unit test execution and application runtime
/// without external asset catalog bundle dependencies.
public final class PixelArtTextureFactory: @unchecked Sendable {
    public static let shared = PixelArtTextureFactory()
    
    private let cacheLock = NSLock()
    private var textureCache: [String: SKTexture] = [:]

    private init() {}

    /// Direction facing for 2D character sprites.
    public enum Direction: String, CaseIterable, Sendable {
        case down
        case up
        case left
        case right
    }

    /// Action animation state for 2D character sprites.
    public enum ActionState: String, CaseIterable, Sendable {
        case idle
        case walk
        case sit
        case read
        case type
        case thinking
        case needsApproval
        case error
        case done
    }

    // MARK: - Character Textures

    /// Generate or fetch a cached character texture for a specific direction, state, and frame.
    public func characterTexture(
        characterId: String = "char_0",
        direction: Direction = .down,
        action: ActionState = .idle,
        frame: Int = 0
    ) -> SKTexture {
        let cacheKey = "char_\(characterId)_\(direction.rawValue)_\(action.rawValue)_\(frame)"
        
        cacheLock.lock()
        if let existing = textureCache[cacheKey] {
            cacheLock.unlock()
            return existing
        }
        cacheLock.unlock()

        let texture = generateCharacterTexture(
            characterId: characterId,
            direction: direction,
            action: action,
            frame: frame
        )
        texture.filteringMode = .nearest

        cacheLock.lock()
        textureCache[cacheKey] = texture
        cacheLock.unlock()

        return texture
    }

    // MARK: - Furniture Textures

    /// Generate or fetch a cached furniture texture for category, direction/variant, and frame.
    public func furnitureTexture(
        category: String,
        variant: String = "front",
        frame: Int = 0
    ) -> SKTexture {
        let cacheKey = "furniture_\(category)_\(variant)_\(frame)"

        cacheLock.lock()
        if let existing = textureCache[cacheKey] {
            cacheLock.unlock()
            return existing
        }
        cacheLock.unlock()

        let texture = generateFurnitureTexture(category: category, variant: variant, frame: frame)
        texture.filteringMode = .nearest

        cacheLock.lock()
        textureCache[cacheKey] = texture
        cacheLock.unlock()

        return texture
    }

    // MARK: - Tile Textures

    /// Generate or fetch a cached floor or wall tile texture.
    public func tileTexture(type: String) -> SKTexture {
        let cacheKey = "tile_\(type)"

        cacheLock.lock()
        if let existing = textureCache[cacheKey] {
            cacheLock.unlock()
            return existing
        }
        cacheLock.unlock()

        let texture = generateTileTexture(type: type)
        texture.filteringMode = .nearest

        cacheLock.lock()
        textureCache[cacheKey] = texture
        cacheLock.unlock()

        return texture
    }

    // MARK: - Speech Bubble Textures

    /// Generate or fetch a speech bubble background texture.
    public func bubbleTexture(style: String = "default") -> SKTexture {
        let cacheKey = "bubble_\(style)"

        cacheLock.lock()
        if let existing = textureCache[cacheKey] {
            cacheLock.unlock()
            return existing
        }
        cacheLock.unlock()

        let texture = generateBubbleTexture(style: style)
        texture.filteringMode = .nearest

        cacheLock.lock()
        textureCache[cacheKey] = texture
        cacheLock.unlock()

        return texture
    }

    // MARK: - Core Graphics Pixel Drawing Helpers

    private func generateCharacterTexture(
        characterId: String,
        direction: Direction,
        action: ActionState,
        frame: Int
    ) -> SKTexture {
        let width = 32
        let height = 32
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        // Palette selector based on characterId ("char_0".."char_5")
        let (skinColor, shirtColor, pantsColor, hairColor) = paletteForCharacter(characterId)

        func setPixel(x: Int, y: Int, color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let index = (y * width + x) * bytesPerPixel
            pixelData[index] = color.r
            pixelData[index + 1] = color.g
            pixelData[index + 2] = color.b
            pixelData[index + 3] = color.a
        }

        func fillRect(x: Int, y: Int, w: Int, h: Int, color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) {
            for px in x..<(x + w) {
                for py in y..<(y + h) {
                    setPixel(x: px, y: py, color: color)
                }
            }
        }

        // Base offsets for pose/action
        var yHead = 20
        var yTorso = 10
        var yLegs = 2
        let xOffset = 0
        var legFrameOffset = 0

        if action == .walk {
            legFrameOffset = (frame % 2 == 0) ? -2 : 2
        } else if action == .sit || action == .type || action == .read {
            yHead -= 4
            yTorso -= 4
            yLegs -= 2
        }

        // Hair / Head
        fillRect(x: 10 + xOffset, y: yHead + 4, w: 12, h: 6, color: hairColor) // Hair top
        fillRect(x: 11 + xOffset, y: yHead, w: 10, h: 6, color: skinColor)      // Face

        // Eyes based on direction
        let eyeColor: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (20, 20, 20, 255)
        switch direction {
        case .down:
            setPixel(x: 13 + xOffset, y: yHead + 2, color: eyeColor)
            setPixel(x: 18 + xOffset, y: yHead + 2, color: eyeColor)
        case .up:
            // Back of head covered by hair
            fillRect(x: 11 + xOffset, y: yHead, w: 10, h: 6, color: hairColor)
        case .left:
            setPixel(x: 12 + xOffset, y: yHead + 2, color: eyeColor)
        case .right:
            setPixel(x: 19 + xOffset, y: yHead + 2, color: eyeColor)
        }

        // Torso
        fillRect(x: 10 + xOffset, y: yTorso, w: 12, h: 9, color: shirtColor)

        // Arms based on action
        let armColor = (action == .type || action == .read) ? skinColor : shirtColor
        if action == .type {
            // Arms forward (typing)
            fillRect(x: 8 + xOffset, y: yTorso + 2, w: 4, h: 3, color: armColor)
            fillRect(x: 20 + xOffset, y: yTorso + 2, w: 4, h: 3, color: armColor)
        } else if action == .read {
            // Arms holding document
            fillRect(x: 12 + xOffset, y: yTorso + 1, w: 8, h: 4, color: (240, 240, 220, 255))
        } else if action == .thinking {
            // Hand on chin
            fillRect(x: 18 + xOffset, y: yTorso + 4, w: 4, h: 4, color: skinColor)
        }

        // Legs
        if action != .sit {
            fillRect(x: 11 + legFrameOffset + xOffset, y: yLegs, w: 4, h: 8, color: pantsColor)
            fillRect(x: 17 - legFrameOffset + xOffset, y: yLegs, w: 4, h: 8, color: pantsColor)
        } else {
            // Seated leg bend
            fillRect(x: 11 + xOffset, y: yLegs + 2, w: 10, h: 4, color: pantsColor)
        }

        return makeTextureFromPixels(data: pixelData, width: width, height: height)
    }

    private func generateFurnitureTexture(category: String, variant: String, frame: Int) -> SKTexture {
        let width = 48
        let height = 48
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        func setPixel(x: Int, y: Int, color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let index = (y * width + x) * bytesPerPixel
            pixelData[index] = color.r
            pixelData[index + 1] = color.g
            pixelData[index + 2] = color.b
            pixelData[index + 3] = color.a
        }

        func fillRect(x: Int, y: Int, w: Int, h: Int, color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) {
            for px in x..<(x + w) {
                for py in y..<(y + h) {
                    setPixel(x: px, y: py, color: color)
                }
            }
        }

        let categoryUpper = category.uppercased()
        let woodColor: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (140, 90, 50, 255)
        let darkWood: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (90, 55, 30, 255)
        let metalColor: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (70, 75, 85, 255)

        switch categoryUpper {
        case "DESK":
            // Desk surface
            fillRect(x: 4, y: 16, w: 40, h: 16, color: woodColor)
            // Desk border shadow
            fillRect(x: 4, y: 16, w: 40, h: 2, color: darkWood)
            // Legs
            fillRect(x: 6, y: 0, w: 4, h: 16, color: metalColor)
            fillRect(x: 38, y: 0, w: 4, h: 16, color: metalColor)

        case "PC":
            // Monitor bezel
            fillRect(x: 14, y: 14, w: 20, h: 16, color: (30, 30, 35, 255))
            // Monitor stand
            fillRect(x: 21, y: 8, w: 6, h: 6, color: (50, 55, 60, 255))
            fillRect(x: 18, y: 6, w: 12, h: 2, color: (50, 55, 60, 255))

            // Screen content based on variant / frame
            if variant.contains("ON") || variant == "on" {
                let glowBlue: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
                switch frame % 3 {
                case 0: glowBlue = (40, 180, 255, 255)
                case 1: glowBlue = (50, 220, 180, 255)
                default: glowBlue = (80, 160, 240, 255)
                }
                fillRect(x: 16, y: 16, w: 16, h: 12, color: glowBlue)
                // Code lines
                let lineCol: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (240, 240, 240, 255)
                fillRect(x: 18, y: 24 - (frame % 3) * 2, w: 10, h: 2, color: lineCol)
                fillRect(x: 18, y: 20, w: 7, h: 2, color: lineCol)
            } else {
                // Off dark glass
                fillRect(x: 16, y: 16, w: 16, h: 12, color: (15, 20, 25, 255))
            }

        case "BOOKSHELF":
            fillRect(x: 8, y: 4, w: 32, h: 40, color: woodColor)
            fillRect(x: 10, y: 14, w: 28, h: 2, color: darkWood)
            fillRect(x: 10, y: 26, w: 28, h: 2, color: darkWood)
            // Books
            fillRect(x: 12, y: 16, w: 4, h: 8, color: (200, 50, 50, 255))
            fillRect(x: 17, y: 16, w: 5, h: 8, color: (50, 160, 80, 255))
            fillRect(x: 23, y: 16, w: 4, h: 8, color: (50, 100, 200, 255))
            fillRect(x: 12, y: 28, w: 6, h: 8, color: (220, 180, 40, 255))
            fillRect(x: 19, y: 28, w: 5, h: 8, color: (180, 70, 190, 255))

        case "CUSHIONED_CHAIR", "CHAIR":
            fillRect(x: 14, y: 14, w: 20, h: 16, color: (50, 110, 180, 255)) // Cushion
            fillRect(x: 16, y: 28, w: 16, h: 14, color: (40, 90, 150, 255))  // Backrest
            fillRect(x: 12, y: 4, w: 4, h: 10, color: metalColor)
            fillRect(x: 32, y: 4, w: 4, h: 10, color: metalColor)

        case "PLANT", "LARGE_PLANT":
            // Pot
            fillRect(x: 18, y: 4, w: 12, h: 10, color: (180, 100, 60, 255))
            // Foliage
            fillRect(x: 12, y: 14, w: 24, h: 24, color: (40, 160, 70, 255))
            fillRect(x: 16, y: 20, w: 16, h: 16, color: (60, 190, 90, 255))

        default:
            // Generic desk object
            fillRect(x: 8, y: 8, w: 32, h: 32, color: woodColor)
        }

        return makeTextureFromPixels(data: pixelData, width: width, height: height)
    }

    private func generateTileTexture(type: String) -> SKTexture {
        let width = 32
        let height = 32
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        func fillRect(x: Int, y: Int, w: Int, h: Int, color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) {
            for px in x..<(x + w) {
                for py in y..<(y + h) {
                    guard px >= 0, px < width, py >= 0, py < height else { continue }
                    let index = (py * width + px) * bytesPerPixel
                    pixelData[index] = color.r
                    pixelData[index + 1] = color.g
                    pixelData[index + 2] = color.b
                    pixelData[index + 3] = color.a
                }
            }
        }

        if type.contains("wall") {
            // Dark gray wall panel
            fillRect(x: 0, y: 0, w: width, h: height, color: (50, 55, 65, 255))
            fillRect(x: 0, y: height - 4, w: width, h: 4, color: (70, 75, 88, 255))
            fillRect(x: 0, y: 0, w: width, h: 2, color: (30, 33, 40, 255))
        } else if type.contains("carpet") {
            // Navy office carpet
            fillRect(x: 0, y: 0, w: width, h: height, color: (35, 45, 60, 255))
            fillRect(x: 0, y: 0, w: width, h: 1, color: (30, 38, 50, 255))
            fillRect(x: 0, y: 0, w: 1, h: height, color: (30, 38, 50, 255))
        } else {
            // Wood floor tile default
            fillRect(x: 0, y: 0, w: width, h: height, color: (160, 110, 65, 255))
            // Plank seams
            fillRect(x: 0, y: 0, w: width, h: 1, color: (130, 85, 45, 255))
            fillRect(x: 0, y: 16, w: width, h: 1, color: (130, 85, 45, 255))
        }

        return makeTextureFromPixels(data: pixelData, width: width, height: height)
    }

    private func generateBubbleTexture(style: String) -> SKTexture {
        let width = 64
        let height = 48
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        func fillRect(x: Int, y: Int, w: Int, h: Int, color: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) {
            for px in x..<(x + w) {
                for py in y..<(y + h) {
                    guard px >= 0, px < width, py >= 0, py < height else { continue }
                    let index = (py * width + px) * bytesPerPixel
                    pixelData[index] = color.r
                    pixelData[index + 1] = color.g
                    pixelData[index + 2] = color.b
                    pixelData[index + 3] = color.a
                }
            }
        }

        let bgCol: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (250, 250, 250, 240)
        let borderCol: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (40, 40, 50, 255)

        // Rounded box
        fillRect(x: 4, y: 8, w: 56, h: 36, color: bgCol)
        // Border outline
        fillRect(x: 4, y: 43, w: 56, h: 2, color: borderCol)
        fillRect(x: 4, y: 8, w: 56, h: 2, color: borderCol)
        fillRect(x: 2, y: 10, w: 2, h: 32, color: borderCol)
        fillRect(x: 60, y: 10, w: 2, h: 32, color: borderCol)
        // Tail
        fillRect(x: 28, y: 2, w: 8, h: 6, color: bgCol)
        fillRect(x: 26, y: 0, w: 4, h: 4, color: borderCol)

        return makeTextureFromPixels(data: pixelData, width: width, height: height)
    }

    private func paletteForCharacter(_ id: String) -> (
        skin: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
        shirt: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
        pants: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
        hair: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
    ) {
        switch id {
        case "char_1":
            return (
                skin: (255, 215, 180, 255),
                shirt: (220, 60, 60, 255),
                pants: (40, 40, 50, 255),
                hair: (60, 40, 20, 255)
            )
        case "char_2":
            return (
                skin: (240, 195, 150, 255),
                shirt: (60, 180, 90, 255),
                pants: (50, 60, 80, 255),
                hair: (220, 180, 40, 255)
            )
        case "char_3":
            return (
                skin: (210, 160, 120, 255),
                shirt: (160, 60, 200, 255),
                pants: (30, 30, 40, 255),
                hair: (30, 30, 30, 255)
            )
        case "char_4":
            return (
                skin: (255, 220, 190, 255),
                shirt: (240, 140, 40, 255),
                pants: (60, 70, 90, 255),
                hair: (180, 50, 40, 255)
            )
        case "char_5":
            return (
                skin: (230, 180, 140, 255),
                shirt: (40, 200, 220, 255),
                pants: (40, 40, 60, 255),
                hair: (200, 200, 210, 255)
            )
        default: // char_0
            return (
                skin: (255, 210, 170, 255),
                shirt: (50, 120, 220, 255),
                pants: (40, 50, 70, 255),
                hair: (40, 30, 20, 255)
            )
        }
    }

    private func makeTextureFromPixels(data: [UInt8], width: Int, height: Int) -> SKTexture {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return SKTexture()
        }

        let texture = SKTexture(cgImage: cgImage)
        texture.filteringMode = .nearest
        return texture
    }
}
