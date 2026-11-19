import Foundation

@MainActor
public final class LocalSlmInstaller {
    public typealias Download = @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> URL

    public var onChange: ((LocalSlmManifest, LocalSlmState, Double?) -> Void)?

    private let directory: URL
    private let download: Download
    private let reporter: ModelInstallReporter
    private var states: [String: LocalSlmState] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var runIDs: [String: UUID] = [:]

    public init(bus: SaysoEventBus, directory: URL = LocalSlmCatalog.modelsDirectory(), download: Download? = nil) {
        self.directory = directory
        self.download = download ?? Self.downloadFromNetwork
        reporter = ModelInstallReporter(bus: bus)
    }

    public func state(for model: LocalSlmManifest) -> LocalSlmState { states[model.id] ?? .notInstalled }

    public func start(_ model: LocalSlmManifest) {
        guard jobs[model.id] == nil else { return }
        let runID = UUID()
        runIDs[model.id] = runID
        states[model.id] = .installing
        reporter.observe(modelID: model.id, displayName: model.displayName, phase: .installing, fraction: 0.05)
        onChange?(model, .installing, 0.05)
        jobs[model.id] = Task {
            do {
                let tempURL = try await download(model.downloadURL) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.runIDs[model.id] == runID else { return }
                        let progress = min(0.99, max(0.05, fraction))
                        self.reporter.observe(modelID: model.id, displayName: model.displayName, phase: .installing, fraction: progress)
                        self.onChange?(model, .installing, progress)
                    }
                }
                defer { try? FileManager.default.removeItem(at: tempURL) }
                guard runIDs[model.id] == runID else { return }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(model.fileName)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                let staging = directory.appendingPathComponent(".\(UUID().uuidString).partial")
                defer { try? FileManager.default.removeItem(at: staging) }
                try FileManager.default.moveItem(at: tempURL, to: staging)
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: staging, to: destination)
                states[model.id] = .installed
                reporter.observe(modelID: model.id, displayName: model.displayName, phase: .installed, fraction: nil)
                onChange?(model, .installed, nil)
            } catch {
                guard runIDs[model.id] == runID else { return }
                let cancelled = Task.isCancelled
                let state: LocalSlmState = cancelled ? .notInstalled : .failed(error.localizedDescription)
                states[model.id] = state
                reporter.observe(modelID: model.id, displayName: model.displayName, phase: cancelled ? .idle : .failed, fraction: nil)
                onChange?(model, state, nil)
            }
            if runIDs[model.id] == runID {
                runIDs.removeValue(forKey: model.id)
                jobs.removeValue(forKey: model.id)
            }
        }
    }

    public func cancel(_ model: LocalSlmManifest) {
        guard let job = jobs.removeValue(forKey: model.id) else { return }
        runIDs.removeValue(forKey: model.id)
        job.cancel()
        states[model.id] = .notInstalled
        reporter.observe(modelID: model.id, displayName: model.displayName, phase: .idle, fraction: nil)
        onChange?(model, .notInstalled, nil)
    }

    private static func downloadFromNetwork(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = SlmDownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tempURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw LocalModelInstallError.unexpectedHTTPStatus(url, (response as? HTTPURLResponse)?.statusCode ?? 500)
        }
        return tempURL
    }
}

private final class SlmDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
