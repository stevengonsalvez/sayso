import CryptoKit
import Foundation

public enum LocalModelInstallError: Error, Equatable, LocalizedError, Sendable {
    case modelLicenseRequiresReview
    case unsupportedHostArchitecture
    case requiredRuntimeUnavailable
    case invalidArtifactPath(String)
    case invalidArtifactURL(URL)
    case unexpectedHTTPStatus(URL, Int)
    case byteCountMismatch(path: String, expected: Int64, actual: Int64)
    case checksumMismatch(path: String)

    public var errorDescription: String? {
        switch self {
        case .modelLicenseRequiresReview: "Model license requires distribution review."
        case .unsupportedHostArchitecture: "Model is unsupported on this Mac architecture."
        case .requiredRuntimeUnavailable: "Required local runtime is not installed."
        case let .invalidArtifactPath(path): "Model artifact path is invalid: \(path)"
        case let .invalidArtifactURL(url): "Model artifact URL is invalid: \(url.absoluteString)"
        case let .unexpectedHTTPStatus(url, status): "Model download failed (HTTP \(status)): \(url.absoluteString)"
        case let .byteCountMismatch(path, expected, actual): "Model artifact size mismatch for \(path): expected \(expected), got \(actual)."
        case let .checksumMismatch(path): "Model artifact checksum mismatch for \(path)."
        }
    }
}

public struct LocalModelInstallation: Equatable, Sendable {
    public let modelID: String
    public let directory: URL
    public let byteCount: Int64

    public init(modelID: String, directory: URL, byteCount: Int64) {
        self.modelID = modelID
        self.directory = directory
        self.byteCount = byteCount
    }
}

/// Downloads a manifest only after its model is usable on this Mac, validates every byte,
/// then moves the complete directory from staging into the model store.
public struct LocalModelDownloader: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let fetch: Fetch

    public init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? Self.fetchFromNetwork
    }

    public func install(
        _ model: LocalModelManifest,
        in modelsDirectory: URL,
        environment: LocalModelEnvironment = .app,
        fileManager: FileManager = .default
    ) async throws -> LocalModelInstallation {
        try validate(model, environment: environment)
        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let stagingRoot = modelsDirectory.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        let stagedModel = stagingRoot.appending(path: model.id, directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: stagingRoot) }
        try fileManager.createDirectory(at: stagedModel, withIntermediateDirectories: true)

        var installedByteCount: Int64 = 0
        for artifact in model.artifacts {
            try validate(artifact)
            let data = try await fetch(artifact.url)
            let actualByteCount = Int64(data.count)
            guard actualByteCount == artifact.byteCount else {
                throw LocalModelInstallError.byteCountMismatch(
                    path: artifact.relativePath,
                    expected: artifact.byteCount,
                    actual: actualByteCount
                )
            }
            guard Self.sha256(of: data) == artifact.sha256.lowercased() else {
                throw LocalModelInstallError.checksumMismatch(path: artifact.relativePath)
            }

            let destination = stagedModel.appending(path: artifact.relativePath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            installedByteCount += actualByteCount
        }

        let marker = stagedModel.appending(path: ".sayso-install-complete")
        try Data(model.id.utf8).write(to: marker, options: .atomic)
        let installationDirectory = modelsDirectory.appending(path: model.id, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: installationDirectory.path) {
            _ = try fileManager.replaceItemAt(installationDirectory, withItemAt: stagedModel)
        } else {
            try fileManager.moveItem(at: stagedModel, to: installationDirectory)
        }
        return .init(modelID: model.id, directory: installationDirectory, byteCount: installedByteCount)
    }

    private func validate(_ model: LocalModelManifest, environment: LocalModelEnvironment) throws {
        guard model.license.isApprovedForDistribution else {
            throw LocalModelInstallError.modelLicenseRequiresReview
        }
        guard model.supportedHostArchitectures.contains(environment.hostArchitecture) else {
            throw LocalModelInstallError.unsupportedHostArchitecture
        }
        guard environment.availableEngines.contains(model.engine) else {
            throw LocalModelInstallError.requiredRuntimeUnavailable
        }
    }

    private func validate(_ artifact: LocalModelArtifact) throws {
        let components = artifact.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !artifact.relativePath.hasPrefix("/"), !components.isEmpty,
              !components.contains(""), !components.contains(".."), !components.contains(".") else {
            throw LocalModelInstallError.invalidArtifactPath(artifact.relativePath)
        }
        guard artifact.url.scheme == "https" else {
            throw LocalModelInstallError.invalidArtifactURL(artifact.url)
        }
    }

    private static func fetchFromNetwork(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LocalModelInstallError.unexpectedHTTPStatus(url, status)
        }
        return data
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
