import Foundation

/// Versioned JSON request/response handler for owner-only local scripts. Transport (the Unix socket) is separate.
public struct SaysoExternalAPI: Sendable {
    public static let version = 1
    static let maxTitleLength = 120
    static let maxStackIDLength = 64
    static let maxExpirySeconds: TimeInterval = 3600
    /// Distinct stacks a script may hold at once, so a runaway script cannot flood the notch.
    public static let maxStacks = 32
    /// Scripts may never raise confirmations: those can interrupt a user pin and approve actions.
    private static let allowedKinds: [String: SaysoActivityKind] = [
        "ambient": .ambient, "activeTask": .activeTask, "completion": .completion, "failure": .failure,
    ]

    private let host: SaysoModuleHost
    private let external: ExternalActivitiesModule

    public init(host: SaysoModuleHost, external: ExternalActivitiesModule) {
        self.host = host
        self.external = external
    }

    public func handle(_ request: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else {
            return Self.encode(["error": "bad_request"])
        }
        guard let number = object["v"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(Self.version) else {
            return Self.encode(["error": "unsupported_version"])
        }
        switch object["op"] as? String {
        case "listModules": return listModules()
        case "publish": return publish(object)
        case "clear": return clear(object)
        default: return Self.encode(["error": "unknown_op"])
        }
    }

    private func listModules() -> Data {
        let modules = host.descriptors.map { descriptor -> [String: Any] in
            ["id": descriptor.id, "title": descriptor.title, "health": "\(host.health(of: descriptor.id))"]
        }
        return Self.encode(["v": Self.version, "modules": modules])
    }

    private func publish(_ object: [String: Any]) -> Data {
        guard let kindName = object["kind"] as? String, let kind = Self.allowedKinds[kindName] else {
            return Self.encode(["error": "invalid_kind"])
        }
        guard let stackID = object["stackID"] as? String, (1...Self.maxStackIDLength).contains(stackID.count),
              let title = object["title"] as? String, (1...Self.maxTitleLength).contains(title.count) else {
            return Self.encode(["error": "invalid_field"])
        }
        var expiry: TimeInterval?
        if let raw = object["expiresAfter"] {
            guard let seconds = (raw as? NSNumber)?.doubleValue, seconds > 0, seconds <= Self.maxExpirySeconds else {
                return Self.encode(["error": "invalid_field"])
            }
            expiry = seconds
        }
        switch external.publish(stackID: stackID, kind: kind, title: title, expiresAfter: expiry, maxStacks: Self.maxStacks) {
        case .published: return Self.encode(["ok": true])
        case .unavailable: return Self.encode(["error": "module_unavailable"])
        case .limitReached: return Self.encode(["error": "limit_reached"])
        }
    }

    private func clear(_ object: [String: Any]) -> Data {
        guard let stackID = object["stackID"] as? String, (1...Self.maxStackIDLength).contains(stackID.count) else {
            return Self.encode(["error": "invalid_field"])
        }
        return external.clear(stackID: stackID) ? Self.encode(["ok": true]) : Self.encode(["error": "module_unavailable"])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
