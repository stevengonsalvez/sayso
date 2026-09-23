import Foundation
import SaysoCore
import SpeakUpstreamBridge

enum SpeakCommand: String {
    case status
    case history
    case start
    case stop
    case transcribe
    case transcribeLocal = "transcribe-local"
    case transcribePunjabi = "transcribe-punjabi"
    case installIndic = "install-indic"
    case installPunjabi = "install-punjabi"
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first.flatMap(SpeakCommand.init(rawValue:)) ?? .status
switch command {
case .installPunjabi:
    let manager = await MainActor.run { SherpaPunjabiModelManager() }
    await manager.install()
    let state = await MainActor.run { manager.state }
    guard state.isInstalled else {
        fputs("Punjabi model install failed: \(state)\n", stderr)
        exit(1)
    }
    print("Punjabi model installed")
case .installIndic:
    let manager = await MainActor.run { FluidAudioLocalModelManager() }
    await manager.install(language: .hindi)
    let state = await MainActor.run { manager.multilingualState }
    guard state.isInstalled else {
        fputs("Indic model install failed: \(state)\n", stderr)
        exit(1)
    }
    print("Indic model installed")
case .transcribeLocal:
    guard arguments.count == 3,
          let language = DictationLanguage.allCases.first(where: {
              $0.rawValue == arguments[1] || $0.displayName.lowercased() == arguments[1].lowercased()
          }) else {
        fputs("Usage: speak transcribe-local <language> /absolute/path/to/audio\n", stderr)
        exit(2)
    }
    do {
        let transcript = try await FileTranscriber.transcribe(
            fileURL: URL(fileURLWithPath: arguments[2]), language: language, route: .local
        )
        print(transcript.text)
    } catch {
        fputs("Local transcription failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
case .transcribePunjabi:
    guard let path = arguments.dropFirst().first else {
        fputs("Usage: speak transcribe-punjabi /absolute/path/to/audio\n", stderr)
        exit(2)
    }
    do {
        let transcript = try await FileTranscriber.transcribe(
            fileURL: URL(fileURLWithPath: path), language: .punjabi, route: .local
        )
        print(transcript.text)
    } catch {
        fputs("Punjabi transcription failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
case .status, .history, .start, .stop, .transcribe:
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
    case .installPunjabi, .installIndic, .transcribePunjabi, .transcribeLocal:
        fatalError("Handled above")
    }
    do {
        let response = try client.send(request)
        let data = try AutomationCoding.encoder().encode(response)
        print(String(decoding: data, as: UTF8.self))
    } catch {
        fputs("Sayso automation unavailable: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
