import Foundation

public struct ModelInstallProgress: SaysoEvent, Equatable {
    public let modelID: String
    public let displayName: String
    /// nil when the manager cannot report progress.
    public let fraction: Double?
    public init(modelID: String, displayName: String, fraction: Double?) {
        self.modelID = modelID
        self.displayName = displayName
        self.fraction = fraction
    }
}

public struct ModelInstallFinished: SaysoEvent, Equatable {
    public let modelID: String
    public let displayName: String
    public let succeeded: Bool
    public init(modelID: String, displayName: String, succeeded: Bool) {
        self.modelID = modelID
        self.displayName = displayName
        self.succeeded = succeeded
    }
}

/// The user asked to retry; whoever owns installation reacts. The models module never installs anything itself.
public struct ModelInstallRetryRequested: SaysoEvent, Equatable {
    public let modelID: String
    public init(modelID: String) { self.modelID = modelID }
}

/// An install stopped without finishing or failing (state went back to not installed); its card must go.
public struct ModelInstallCancelled: SaysoEvent, Equatable {
    public let modelID: String
    public init(modelID: String) { self.modelID = modelID }
}
