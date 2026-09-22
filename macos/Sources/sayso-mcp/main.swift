import Foundation
import SaysoCore
import SpeakUpstreamBridge

private enum SaysoMCP {
    static let protocolVersion = "2025-06-18"
    static var tools: [[String: Any]] { [
        [
            "name": AutomationCommand.transcribeFile.rawValue,
            "description": "Transcribe a local audio file with Sayso Notch.",
            "inputSchema": [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "Absolute audio-file path."]],
                "required": ["path"]
            ]
        ],
        [
            "name": AutomationCommand.history.rawValue,
            "description": "Return recent Sayso Notch transcriptions, newest first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "minimum": 1, "maximum": AutomationLimits.maxHistoryLimit]
                ]
            ]
        ],
        [
            "name": AutomationCommand.startDictation.rawValue,
            "description": "Start Sayso Notch dictation.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": AutomationCommand.stopDictation.rawValue,
            "description": "Stop Sayso Notch dictation and return its transcript.",
            "inputSchema": ["type": "object", "properties": [:]]
        ]
    ] }

    static func handle(_ line: String, client: UnixSocketAutomationClient) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count <= AutomationLimits.maxFrameBytes else {
            return encode(error(id: nil, code: -32600, message: "Request exceeds the size limit."))
        }
        guard let data = trimmed.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = message["method"] as? String else {
            return encode(error(id: nil, code: -32700, message: "Parse error: invalid JSON."))
        }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return encode(result(id: id, value: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "sayso-notch", "version": "1.0.0"],
                "instructions": "Owner-only Sayso Notch dictation controls. Credentials remain in the app."
            ]))
        case "ping":
            return encode(result(id: id, value: [:]))
        case "tools/list":
            return encode(result(id: id, value: ["tools": tools]))
        case "tools/call":
            return encode(call(id: id, params: params, client: client))
        default:
            return encode(error(id: id, code: -32601, message: "Method not found: \(method)."))
        }
    }

    private static func call(id: Any, params: [String: Any], client: UnixSocketAutomationClient) -> [String: Any] {
        guard let name = params["name"] as? String,
              let command = AutomationCommand(rawValue: name),
              command != .status else {
            return error(id: id, code: -32602, message: "Unknown tool.")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        var request = AutomationRequest(id: requestID(id), command: command)
        if command == .transcribeFile {
            guard let path = arguments["path"] as? String, path.hasPrefix("/") else {
                return error(id: id, code: -32602, message: "path must be an absolute audio-file path.")
            }
            request.path = path
        }
        if command == .history, let limit = arguments["limit"] {
            guard let value = limit as? Int, (1...AutomationLimits.maxHistoryLimit).contains(value) else {
                return error(id: id, code: -32602, message: "limit must be an integer between 1 and \(AutomationLimits.maxHistoryLimit).")
            }
            request.limit = value
        }
        do {
            let response = try client.send(request.validated())
            let text: String
            let structured: [String: Any]?
            if response.ok, let value = response.result {
                let data = try AutomationCoding.encoder().encode(value)
                text = String(decoding: data, as: UTF8.self)
                structured = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            } else {
                let failure = response.error ?? AutomationError(code: .internalError, message: "Sayso did not return a result.")
                text = "\(failure.code.rawValue): \(failure.message)"
                structured = nil
            }
            var payload: [String: Any] = [
                "content": [["type": "text", "text": text]],
                "isError": !response.ok
            ]
            if let structured { payload["structuredContent"] = structured }
            return result(id: id, value: payload)
        } catch {
            return result(id: id, value: [
                "content": [["type": "text", "text": "app_unavailable: Sayso Notch automation is unavailable."]],
                "isError": true
            ])
        }
    }

    private static func requestID(_ id: Any) -> String {
        String(("mcp-" + String(describing: id)).prefix(AutomationLimits.maxIdentifierLength))
    }

    private static func result(id: Any, value: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    private static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{\"error\":{\"code\":-32603,\"message\":\"Encoding failure\"},\"id\":null,\"jsonrpc\":\"2.0\"}"#
        }
        return text
    }
}

let client = UnixSocketAutomationClient(socketPath: SaysoAutomationEndpoint.socketPath)
while let line = readLine() {
    if let response = SaysoMCP.handle(line, client: client) {
        print(response)
    }
}
