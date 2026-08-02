import XCTest
import SpriteKit
@testable import CmuxAgentChat

@MainActor
final class AgentStudioRenderTests: XCTestCase {

    // MARK: - PixelArtTextureFactory Tests

    func testPixelArtTextureFactory_TextureGenerationAndNearestFiltering() {
        let factory = PixelArtTextureFactory.shared

        // 1. Character Texture
        let charTex = factory.characterTexture(characterId: "char_0", direction: .down, action: .idle, frame: 0)
        XCTAssertNotNil(charTex)
        XCTAssertEqual(charTex.filteringMode, .nearest)

        // 2. Character Walk & Action Textures
        for dir in PixelArtTextureFactory.Direction.allCases {
            for action in PixelArtTextureFactory.ActionState.allCases {
                let tex = factory.characterTexture(characterId: "char_1", direction: dir, action: action, frame: 1)
                XCTAssertNotNil(tex)
                XCTAssertEqual(tex.filteringMode, .nearest)
            }
        }

        // 3. Furniture Textures
        let deskTex = factory.furnitureTexture(category: "DESK", variant: "front", frame: 0)
        XCTAssertNotNil(deskTex)
        XCTAssertEqual(deskTex.filteringMode, .nearest)

        let pcTexOn = factory.furnitureTexture(category: "PC", variant: "on", frame: 1)
        XCTAssertNotNil(pcTexOn)
        XCTAssertEqual(pcTexOn.filteringMode, .nearest)

        // 4. Tile Textures
        let carpetTex = factory.tileTexture(type: "carpet")
        XCTAssertNotNil(carpetTex)
        XCTAssertEqual(carpetTex.filteringMode, .nearest)

        let wallTex = factory.tileTexture(type: "wall")
        XCTAssertNotNil(wallTex)
        XCTAssertEqual(wallTex.filteringMode, .nearest)

        // 5. Caching verification
        let cachedTex = factory.characterTexture(characterId: "char_0", direction: .down, action: .idle, frame: 0)
        XCTAssertTrue(charTex === cachedTex, "Texture factory should return cached instance for identical keys")
    }

    // MARK: - OfficeGridNode Tests

    func testOfficeGridNode_LayoutAndCoordinateMapping() {
        let gridNode = OfficeGridNode(columns: 20, rows: 15, tileSize: CGSize(width: 32, height: 32))

        XCTAssertEqual(gridNode.columns, 20)
        XCTAssertEqual(gridNode.rows, 15)
        XCTAssertEqual(gridNode.tilesLayer.children.count, 20 * 15)

        // Position mapping check
        let centerPos = gridNode.positionForGrid(column: 10, row: 7)
        let (col, row) = gridNode.gridForPosition(centerPos)
        XCTAssertEqual(col, 10)
        XCTAssertEqual(row, 7)

        // Desk & Seat positions
        let (deskPos0, seatPos0) = gridNode.deskPosition(forSeatIndex: 0)
        XCTAssertNotEqual(deskPos0, .zero)
        XCTAssertNotEqual(seatPos0, .zero)
        XCTAssertLessThan(seatPos0.y, deskPos0.y, "Seat should be positioned slightly below desk")
    }

    // MARK: - FurnitureNode Tests

    func testFurnitureNode_InitializationAndPCStateAnimation() {
        let desk = FurnitureNode(category: .desk, position: CGPoint(x: 100, y: 100))
        XCTAssertEqual(desk.category, .desk)
        XCTAssertEqual(desk.position, CGPoint(x: 100, y: 100))

        let pc = FurnitureNode(category: .pc, position: CGPoint(x: 100, y: 120))
        XCTAssertEqual(pc.category, .pc)
        XCTAssertEqual(pc.pcState, .off)

        // Change state
        pc.setPCState(.screen1)
        XCTAssertEqual(pc.pcState, .screen1)

        // Test screen animation toggle
        pc.animatePCScreen(isTyping: true)
        XCTAssertNotNil(pc.action(forKey: "pcScreenAnimation"), "PC node should run animation action when typing")

        pc.animatePCScreen(isTyping: false)
        XCTAssertNil(pc.action(forKey: "pcScreenAnimation"), "PC node should stop animation action when not typing")
        XCTAssertEqual(pc.pcState, .off)
    }

    // MARK: - SpeechBubbleNode Tests

    func testSpeechBubbleNode_TypesAndVisibilityTransitions() {
        let bubble = SpeechBubbleNode(type: .thinking)
        XCTAssertFalse(bubble.isVisible)

        bubble.show(type: .thinking)
        XCTAssertTrue(bubble.isVisible)
        XCTAssertEqual(bubble.currentType, .thinking)

        bubble.show(type: .needsApproval, text: "ALLOW?")
        XCTAssertTrue(bubble.isVisible)
        XCTAssertEqual(bubble.currentType, .needsApproval)

        bubble.show(type: .error, text: "FAILED")
        XCTAssertTrue(bubble.isVisible)
        XCTAssertEqual(bubble.currentType, .error)

        bubble.show(type: .done)
        XCTAssertTrue(bubble.isVisible)
        XCTAssertEqual(bubble.currentType, .done)

        let exp = expectation(description: "Hide animation complete")
        bubble.hide {
            XCTAssertFalse(bubble.isVisible)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - DigitalRainNode Tests

    func testDigitalRainNode_StartAndStopRain() {
        let rainNode = DigitalRainNode(columnsCount: 6, rainWidth: 100, rainHeight: 120)
        XCTAssertFalse(rainNode.isActive)

        rainNode.startRain()
        XCTAssertTrue(rainNode.isActive)

        rainNode.stopRain(fadeDuration: 0.1)
        XCTAssertFalse(rainNode.isActive)
    }

    // MARK: - CharacterSpriteNode & FSM Binding Tests

    func testCharacterSpriteNode_FSMStateTransitions() {
        let character = CharacterSpriteNode(agentId: "agent-test", characterId: "char_0", position: CGPoint(x: 50, y: 50))
        XCTAssertEqual(character.currentState, .idle)
        XCTAssertFalse(character.speechBubbleNode.isVisible)
        XCTAssertFalse(character.digitalRainNode.isActive)

        // 1. Walk transition
        character.transition(to: .walk)
        XCTAssertEqual(character.currentState, .walk)

        // 2. Active Type transition -> Should trigger Digital Rain
        character.transition(to: .activeType)
        XCTAssertEqual(character.currentState, .activeType)
        XCTAssertTrue(character.digitalRainNode.isActive, "activeType should start matrix digital rain cascade")
        XCTAssertEqual(character.currentDirection, .up)

        // 3. Active Read transition -> Stops Digital Rain
        character.transition(to: .activeRead)
        XCTAssertEqual(character.currentState, .activeRead)
        XCTAssertFalse(character.digitalRainNode.isActive, "activeRead should stop matrix digital rain")

        // 4. Thinking transition -> Shows Thinking Bubble
        character.transition(to: .thinking, message: "Pondering solution...")
        XCTAssertEqual(character.currentState, .thinking)
        XCTAssertTrue(character.speechBubbleNode.isVisible)
        XCTAssertEqual(character.speechBubbleNode.currentType, .thinking)

        // 5. Needs Approval transition -> Shows Approval Bubble
        character.transition(to: .needsApproval, message: "Execute command?")
        XCTAssertEqual(character.currentState, .needsApproval)
        XCTAssertTrue(character.speechBubbleNode.isVisible)
        XCTAssertEqual(character.speechBubbleNode.currentType, .needsApproval)

        // 6. Error transition -> Shows Error Bubble
        character.transition(to: .error, message: "Build error")
        XCTAssertEqual(character.currentState, .error)
        XCTAssertTrue(character.speechBubbleNode.isVisible)
        XCTAssertEqual(character.speechBubbleNode.currentType, .error)

        // 7. Done transition -> Shows Done Bubble
        character.transition(to: .done)
        XCTAssertEqual(character.currentState, .done)
        XCTAssertTrue(character.speechBubbleNode.isVisible)
        XCTAssertEqual(character.speechBubbleNode.currentType, .done)

        // 8. Return to Idle
        character.transition(to: .idle)
        XCTAssertEqual(character.currentState, .idle)
        XCTAssertFalse(character.speechBubbleNode.isVisible)
        XCTAssertFalse(character.digitalRainNode.isActive)
    }

    // MARK: - AgentStudioScene Tests

    func testAgentStudioScene_InitializationAndFSMBinding() {
        let scene = AgentStudioScene(size: CGSize(width: 800, height: 600))

        XCTAssertNotNil(scene.gridNode)
        XCTAssertGreaterThan(scene.furnitureNodes.count, 0, "Scene should contain default furniture layout")

        // Add Agent
        let character = scene.addAgent(id: "agent-alpha", characterId: "char_2", seatIndex: 1)
        XCTAssertNotNil(character)
        XCTAssertEqual(scene.characterNodes["agent-alpha"]?.agentId, "agent-alpha")

        // Bind AgentFSM
        let fsm = AgentFSM(initialState: .idle)
        scene.bind(fsm: fsm, forAgentId: "agent-alpha")

        // Process Canonical Events through FSM and verify scene synchronization
        fsm.handle(event: CanonicalEvent(kind: .userPrompt, text: "Build project"))
        XCTAssertEqual(character.currentState, .walk)

        // Tool start -> activeType
        fsm.handle(event: CanonicalEvent(kind: .toolStart, toolName: "write_to_file"))
        XCTAssertEqual(character.currentState, .activeType)
        XCTAssertTrue(character.digitalRainNode.isActive)

        // Permission required -> needsApproval
        fsm.handle(event: CanonicalEvent(kind: .permissionRequired, toolName: "run_command"))
        XCTAssertEqual(character.currentState, .needsApproval)
        XCTAssertTrue(character.speechBubbleNode.isVisible)
        XCTAssertEqual(character.speechBubbleNode.currentType, .needsApproval)

        // Remove Agent
        scene.removeAgent(id: "agent-alpha")
        XCTAssertNil(scene.characterNodes["agent-alpha"])
    }
}
