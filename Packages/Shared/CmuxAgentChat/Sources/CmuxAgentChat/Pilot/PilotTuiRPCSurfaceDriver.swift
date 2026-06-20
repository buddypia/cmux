import CoreFoundation
import Foundation

/// A small Sendable JSON-RPC value vocabulary for Pilot surface commands.
public enum PilotTuiRPCValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    public var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    public var jsonObject: Any {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    public init?(jsonObject: Any) {
        switch jsonObject {
        case let value as String:
            self = .string(value)
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(value)
        case is NSNull:
            self = .null
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
            self = .bool(value.boolValue)
        case let value as NSNumber:
            let double = value.doubleValue
            guard double.isFinite, double.rounded(.towardZero) == double else {
                return nil
            }
            self = .int(value.intValue)
        default:
            return nil
        }
    }

    public static func jsonObjectDictionary(
        from values: [String: PilotTuiRPCValue]
    ) -> [String: Any] {
        values.mapValues(\.jsonObject)
    }

    public static func dictionary(
        from jsonObject: [String: Any]
    ) -> [String: PilotTuiRPCValue] {
        jsonObject.compactMapValues { PilotTuiRPCValue(jsonObject: $0) }
    }
}

/// Stable routing selectors for cmux surface JSON-RPC calls.
public struct PilotTuiSurfaceTarget: Sendable, Equatable {
    public let windowID: String?
    public let workspaceID: String?
    public let surfaceID: String?

    public init(windowID: String? = nil, workspaceID: String? = nil, surfaceID: String? = nil) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
    }

    var rpcParams: [String: PilotTuiRPCValue] {
        var params: [String: PilotTuiRPCValue] = [:]
        if let windowID {
            params["window_id"] = .string(windowID)
        }
        if let workspaceID {
            params["workspace_id"] = .string(workspaceID)
        }
        if let surfaceID {
            params["surface_id"] = .string(surfaceID)
        }
        return params
    }
}

/// Maps Pilot surface operations to cmux JSON-RPC methods.
public struct PilotTuiRPCSurfaceDriver: PilotTuiSurfaceDriving {
    public typealias Transport = @Sendable (
        _ method: String,
        _ params: [String: PilotTuiRPCValue]
    ) async throws -> [String: PilotTuiRPCValue]

    private let target: PilotTuiSurfaceTarget
    private let transport: Transport

    public init(target: PilotTuiSurfaceTarget = PilotTuiSurfaceTarget(), transport: @escaping Transport) {
        self.target = target
        self.transport = transport
    }

    public func readScreen(options: PilotTuiSurfaceReadOptions) async throws -> String {
        var params = target.rpcParams
        params["lines"] = .int(options.lines)
        params["scrollback"] = .bool(true)
        let response = try await transport("surface.read_text", params)
        return response["text"]?.stringValue ?? ""
    }

    public func sendKey(_ key: PilotTuiKey) async throws {
        var params = target.rpcParams
        params["key"] = .string(key.rawValue)
        _ = try await transport("surface.send_key", params)
    }

    public func sendText(_ text: String) async throws {
        var params = target.rpcParams
        params["text"] = .string(text)
        _ = try await transport("surface.send_text", params)
    }

    public func notify(_ notification: PilotTuiSurfaceNotification) async throws {
        var params = target.rpcParams
        params["title"] = .string(notification.title)
        params["body"] = .string(notification.body)
        _ = try await transport("notification.create", params)
    }
}
