import AppKit
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
    case acceptance
}

@MainActor
private func runAcceptance(text: String, targetBundleIdentifier: String) async -> [String: Any] {
    guard let application = NSWorkspace.shared.frontmostApplication,
          application.bundleIdentifier == targetBundleIdentifier,
          let destination = TextOutput.captureDestination(
              targetProcessIdentifier: application.processIdentifier
          ) else {
        return ["ok": false, "error": "Named target is not the safe focused text destination."]
    }

    let words = text.split(whereSeparator: \.isWhitespace)
    let checkpoints = stride(from: min(2, words.count), to: words.count, by: 2)
    let stepDelay = ProcessInfo.processInfo.environment["SAYSO_ACCEPTANCE_STEP_DELAY_MS"]
        .flatMap(Int.init) ?? 700
    let liveInsertion = TextOutput.LiveInsertion(destination: destination)
    var partials: [[String: Any]] = []
    for checkpoint in checkpoints {
        let partial = words.prefix(checkpoint).joined(separator: " ")
        let applied = liveInsertion?.update(partial) ?? false
        partials.append(["text": partial, "applied": applied])
        try? await Task.sleep(for: .milliseconds(stepDelay))
    }

    let output: TextOutput.DeliveryResult
    if let liveInsertion {
        switch liveInsertion.finalize(text) {
        case .applied:
            output = .delivered(liveInsertion.deliveryMethod)
        case .deferred:
            output = TextOutput.insertOrCopy(text, destination: destination)
        case .failed:
            output = TextOutput.copy(text)
                ? .delivered(.clipboard)
                : .pasteFailed(.clipboardUnavailable)
        }
    } else {
        output = TextOutput.insertOrCopy(text, destination: destination)
    }
    try? await Task.sleep(for: .milliseconds(900))

    var result: [String: Any] = [
        "ok": true,
        "target": destination.recordingDestination.applicationName,
        "fieldRole": destination.recordingDestination.fieldRole,
        "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
        "liveInsertionAvailable": liveInsertion != nil,
        "liveInsertionWrote": liveInsertion?.hasWritten ?? false,
        "partials": partials,
        "targetCanPaste": TextOutput.canPaste(into: destination),
    ]
    let delivery: AcceptanceVerdict.Delivery
    switch output {
    case let .delivered(method):
        result["delivery"] = method.rawValue
        delivery = method == .clipboard ? .clipboard : .inserted
    case let .pasteFailed(failure):
        delivery = .failed(failure.userMessage)
    }
    let verdict = AcceptanceVerdict.evaluate(
        expectedText: text,
        partialsApplied: partials.map { ($0["applied"] as? Bool) ?? false },
        delivery: delivery,
        observedTargetValue: TextOutput.currentValue(in: destination)
    )
    result["ok"] = verdict.ok
    if let error = verdict.error { result["error"] = error }
    return result
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
case .acceptance:
    let acceptanceArguments = Array(arguments.dropFirst())
    guard acceptanceArguments.count >= 3, acceptanceArguments[0] == "--target" else {
        fputs("Usage: sayso acceptance --target <bundle-id> <text>\n", stderr)
        exit(2)
    }
    let targetBundleIdentifier = acceptanceArguments[1]
    let text = acceptanceArguments.dropFirst(2).joined(separator: " ")
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fputs("Usage: sayso acceptance --target <bundle-id> <text>\n", stderr)
        exit(2)
    }
    let result = await runAcceptance(text: text, targetBundleIdentifier: targetBundleIdentifier)
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    if result["ok"] as? Bool != true { exit(1) }
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
    case .installPunjabi, .installIndic, .transcribePunjabi, .transcribeLocal, .acceptance:
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
