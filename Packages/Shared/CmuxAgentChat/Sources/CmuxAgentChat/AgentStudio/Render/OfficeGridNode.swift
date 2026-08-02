import SpriteKit
import CoreGraphics

/// Node rendering the 2D office floor and wall tile grid for Agent Studio.
@MainActor
public class OfficeGridNode: SKNode {
    public let columns: Int
    public let rows: Int
    public let tileSize: CGSize

    /// Container layer node holding tile sprites.
    public private(set) var tilesLayer: SKNode = SKNode()

    public init(
        columns: Int = 20,
        rows: Int = 15,
        tileSize: CGSize = CGSize(width: 32, height: 32)
    ) {
        self.columns = columns
        self.rows = rows
        self.tileSize = tileSize
        super.init()

        addChild(tilesLayer)
        buildGrid()
    }

    required init?(coder aDecoder: NSCoder) {
        self.columns = 20
        self.rows = 15
        self.tileSize = CGSize(width: 32, height: 32)
        super.init(coder: aDecoder)

        addChild(tilesLayer)
        buildGrid()
    }

    // MARK: - Grid Construction

    /// Rebuilds the tile grid layout (wall top row, carpet floor center, wood borders).
    public func buildGrid() {
        tilesLayer.removeAllChildren()

        for r in 0..<rows {
            for c in 0..<columns {
                let pos = positionForGrid(column: c, row: r)
                let tileType: String

                if r >= rows - 2 {
                    // Top 2 rows are wall tiles
                    tileType = "wall"
                } else if c == 0 || c == columns - 1 || r == 0 {
                    // Border wood floor
                    tileType = "wood"
                } else {
                    // Main office floor carpet
                    tileType = "carpet"
                }

                let texture = PixelArtTextureFactory.shared.tileTexture(type: tileType)
                let tileSprite = SKSpriteNode(texture: texture, size: tileSize)
                tileSprite.position = pos
                tileSprite.zPosition = (tileType == "wall") ? 10 : 0
                tilesLayer.addChild(tileSprite)
            }
        }
    }

    // MARK: - Coordinate Mapping Helpers

    /// Converts integer grid coordinates (column, row) to node `CGPoint` space.
    public func positionForGrid(column: Int, row: Int) -> CGPoint {
        let originX = -CGFloat(columns) * tileSize.width * 0.5 + tileSize.width * 0.5
        let originY = -CGFloat(rows) * tileSize.height * 0.5 + tileSize.height * 0.5

        let x = originX + CGFloat(column) * tileSize.width
        let y = originY + CGFloat(row) * tileSize.height
        return CGPoint(x: x, y: y)
    }

    /// Converts `CGPoint` in node space to nearest integer grid coordinates (column, row).
    public func gridForPosition(_ point: CGPoint) -> (column: Int, row: Int) {
        let originX = -CGFloat(columns) * tileSize.width * 0.5 + tileSize.width * 0.5
        let originY = -CGFloat(rows) * tileSize.height * 0.5 + tileSize.height * 0.5

        let col = Int(round((point.x - originX) / tileSize.width))
        let row = Int(round((point.y - originY) / tileSize.height))

        let clampedCol = max(0, min(columns - 1, col))
        let clampedRow = max(0, min(rows - 1, row))

        return (clampedCol, clampedRow)
    }

    /// Returns standard desk position and seat position for a given seat index.
    public func deskPosition(forSeatIndex index: Int) -> (deskPos: CGPoint, seatPos: CGPoint) {
        let seatOffsets: [(col: Int, row: Int)] = [
            (3, 8),
            (8, 8),
            (13, 8),
            (3, 4),
            (8, 4),
            (13, 4)
        ]

        let gridCoords = seatOffsets[index % seatOffsets.count]
        let deskPos = positionForGrid(column: gridCoords.col, row: gridCoords.row)
        // Seat is positioned slightly below desk
        let seatPos = CGPoint(x: deskPos.x, y: deskPos.y - tileSize.height * 0.6)

        return (deskPos: deskPos, seatPos: seatPos)
    }
}
