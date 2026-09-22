import Foundation
import SaysoCore
import SpeakUpstreamBridge

enum SpeakCommand: String {
    case status
    case history
    case start
    case stop
    case transcribe
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first.flatMap(SpeakCommand.init(rawValue:)) ?? .status
let client = UnixSocketAutomationClient(socketPath: SaysoAutomationEndpoint.socketPath)
let request: AutomationRequest
switch command {
case .status: request = .init(command: .status)
case .history: request = .init(command: .history)
case .start: request = .init(command: .startDictation)
case .stop: request = .init(command: .stopDictation)
case .transcribe:
    guard let path = arguments.dropFirst().first else {
        fputs("Usage: speak transcribe /absolute/path/to/audio\n", stderr)
        exit(2)
    }
    request = .init(command: .transcribeFile, path: URL(fileURLWithPath: path).path)
}

do {
    let response = try client.send(request)
    let data = try AutomationCoding.encoder().encode(response)
    print(String(decoding: data, as: UTF8.self))
} catch {
    fputs("Sayso automation unavailable: \(error.localizedDescription)\n", stderr)
    exit(1)
}
