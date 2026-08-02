import SpriteKit
import CoreGraphics

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Main SpriteKit scene rendering the 2D pixel-art office workspace in Agent Studio.
@MainActor
public class AgentStudioScene: SKScene {

    /// Background tile grid layer (floor and walls).
    public private(set) var gridNode: OfficeGridNode

    /// List of furniture nodes in scene (desks, PCs, chairs, plants).
    public private(set) var furnitureNodes: [FurnitureNode] = []

    /// Dictionary of agent character nodes indexed by agent ID.
    public private(set) var characterNodes: [String: CharacterSpriteNode] = [:]

    /// Dictionary of bound `AgentFSM` state machines indexed by agent ID.
    public private(set) var fsms: [String: AgentFSM] = [:]

    /// Selection callback fired when user clicks/taps an agent character node.
    public var onAgentSelected: ((String) -> Void)?

    /// Selection callback fired when user clicks/taps a desk seat location index.
    public var onSeatSelected: ((Int) -> Void)?

    public override init(size: CGSize = CGSize(width: 800, height: 600)) {
        self.gridNode = OfficeGridNode(columns: 20, rows: 15, tileSize: CGSize(width: 32, height: 32))
        super.init(size: size)

        self.scaleMode = .resizeFill
        self.backgroundColor = SKColor(red: 0.1, green: 0.12, blue: 0.15, alpha: 1.0)

        addChild(gridNode)
        setupDefaultOfficeLayout()
    }

    required init?(coder aDecoder: NSCoder) {
        self.gridNode = OfficeGridNode()
        super.init(coder: aDecoder)

        self.scaleMode = .resizeFill
        addChild(gridNode)
        setupDefaultOfficeLayout()
    }

    // MARK: - Office Layout Construction

    /// Set up standard office layout with desks, computer monitors, chairs, plants, and bookshelves.
    public func setupDefaultOfficeLayout() {
        // Clear existing furniture
        furnitureNodes.forEach { $0.removeFromParent() }
        furnitureNodes.removeAll()

        for seatIdx in 0..<6 {
            let (deskPos, seatPos) = gridNode.deskPosition(forSeatIndex: seatIdx)

            // Add Desk
            let desk = FurnitureNode(category: .desk, position: deskPos, zPosition: 20, variant: "front")
            addChild(desk)
            furnitureNodes.append(desk)

            // Add PC monitor on desk
            let pcPos = CGPoint(x: deskPos.x, y: deskPos.y + 8)
            let pc = FurnitureNode(category: .pc, position: pcPos, zPosition: 22, variant: "off")
            addChild(pc)
            furnitureNodes.append(pc)

            // Add Chair at seat position
            let chair = FurnitureNode(category: .chair, position: seatPos, zPosition: 15, variant: "front")
            addChild(chair)
            furnitureNodes.append(chair)
        }

        // Add Decorative Bookshelf & Plant
        let bookshelfPos = gridNode.positionForGrid(column: 17, row: 12)
        let bookshelf = FurnitureNode(category: .bookshelf, position: bookshelfPos, zPosition: 12)
        addChild(bookshelf)
        furnitureNodes.append(bookshelf)

        let plantPos = gridNode.positionForGrid(column: 2, row: 12)
        let plant = FurnitureNode(category: .plant, position: plantPos, zPosition: 12)
        addChild(plant)
        furnitureNodes.append(plant)
    }

    // MARK: - Agent Management & FSM Binding

    /// Add or update an agent character node in the scene.
    @discardableResult
    public func addAgent(
        id: String,
        characterId: String = "char_0",
        seatIndex: Int? = nil
    ) -> CharacterSpriteNode {
        if let existing = characterNodes[id] {
            return existing
        }

        let assignedIndex = seatIndex ?? (characterNodes.count % 6)
        let (deskPos, seatPos) = gridNode.deskPosition(forSeatIndex: assignedIndex)

        let character = CharacterSpriteNode(
            agentId: id,
            characterId: characterId,
            position: seatPos
        )
        character.homeSeatPosition = seatPos
        character.homeDeskPosition = deskPos

        addChild(character)
        characterNodes[id] = character
        return character
    }

    /// Remove an agent character node from the scene.
    public func removeAgent(id: String) {
        fsms.removeValue(forKey: id)
        if let node = characterNodes.removeValue(forKey: id) {
            node.removeFromParent()
        }
    }

    /// Bind an ``AgentFSM`` instance directly to an agent character node in the scene.
    public func bind(fsm: AgentFSM, forAgentId id: String) {
        let characterNode = addAgent(id: id)
        fsms[id] = fsm

        // Wire FSM onStateChange callback directly to character node state transition
        fsm.onStateChange = { [weak self, weak characterNode] state, event in
            let updateBlock: @MainActor @Sendable () -> Void = {
                characterNode?.transition(to: state, message: event?.summary)
                self?.synchronizeFurnitureState(forAgentId: id, state: state)
            }

            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    updateBlock()
                }
            } else {
                DispatchQueue.main.async(execute: updateBlock)
            }
        }

        // Apply initial state
        characterNode.transition(to: fsm.currentState)
    }

    /// Manually update an agent's state in the scene.
    public func updateAgentState(id: String, state: AgentState, message: String? = nil) {
        guard let character = characterNodes[id] else { return }
        character.transition(to: state, message: message)
        synchronizeFurnitureState(forAgentId: id, state: state)
    }

    // MARK: - Private Helpers

    private func synchronizeFurnitureState(forAgentId id: String, state: AgentState) {
        guard let character = characterNodes[id] else { return }

        // Find nearest PC node to character home desk
        for furniture in furnitureNodes where furniture.category == .pc {
            let distance = hypot(furniture.position.x - character.homeDeskPosition.x, furniture.position.y - character.homeDeskPosition.y)
            if distance < 30 {
                let isTyping = (state == .activeType)
                furniture.animatePCScreen(isTyping: isTyping)
            }
        }
    }

    // MARK: - Event Selection Handling

    public func handleSelect(at location: CGPoint) {
        let touchedNodes = nodes(at: location)

        for node in touchedNodes {
            if let character = node as? CharacterSpriteNode ?? node.parent as? CharacterSpriteNode {
                onAgentSelected?(character.agentId)
                return
            }

            if let furniture = node as? FurnitureNode ?? node.parent as? FurnitureNode {
                // Find corresponding seat index
                for idx in 0..<6 {
                    let (deskPos, _) = gridNode.deskPosition(forSeatIndex: idx)
                    let dist = hypot(furniture.position.x - deskPos.x, furniture.position.y - deskPos.y)
                    if dist < 40 {
                        onSeatSelected?(idx)
                        return
                    }
                }
            }
        }
    }

#if os(macOS)
    public override func mouseDown(with event: NSEvent) {
        let location = event.location(in: self)
        handleSelect(at: location)
    }
#else
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        handleSelect(at: location)
    }
#endif
}
