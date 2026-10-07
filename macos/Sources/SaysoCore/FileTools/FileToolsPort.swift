import Foundation

public enum FileToolsImageFormat: String, CaseIterable, Sendable {
    case png, jpeg, heic

    public var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }
}

/// What a file holds, read from its first bytes rather than its name.
public enum FileToolsContentType: Equatable, Sendable {
    case png, jpeg, heic, pdf, other

    var imageFormat: FileToolsImageFormat? {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .pdf, .other: nil
        }
    }
}

public enum FileToolsTool: Equatable, Sendable {
    /// One zip of every named file or folder.
    case zip
    /// One image into another format; `quality` (0.1 to 1) applies to JPEG and HEIC.
    case convertImage(FileToolsImageFormat, quality: Double)
    /// Two or more PDFs into one, in the order named.
    case mergePDFs
}

/// Facts about one named input, gathered before any work starts.
public struct FileToolsInput: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case missing, file, directory, other }

    /// As the user named it.
    public let url: URL
    /// After following a symbolic link; the same as `url` otherwise.
    public let resolved: URL
    public let kind: Kind
    /// For a folder, the size of every file inside it.
    public let byteCount: Int64
    public let contentType: FileToolsContentType
    /// A symbolic link (the input itself, or one inside a named folder) that points outside the input's folder.
    public let escapesFolder: Bool

    public init(
        url: URL, resolved: URL? = nil, kind: Kind, byteCount: Int64 = 0,
        contentType: FileToolsContentType = .other, escapesFolder: Bool = false
    ) {
        self.url = url
        self.resolved = resolved ?? url
        self.kind = kind
        self.byteCount = byteCount
        self.contentType = contentType
        self.escapesFolder = escapesFolder
    }

    public var name: String { url.lastPathComponent }
}

/// Validated work for the port: write one new file in `folder`, named `name` or the first free name after it.
public struct FileToolsJob: Equatable, Sendable {
    public let tool: FileToolsTool
    public let inputs: [FileToolsInput]
    public let folder: URL
    public let name: String

    public init(tool: FileToolsTool, inputs: [FileToolsInput], folder: URL, name: String) {
        self.tool = tool
        self.inputs = inputs
        self.folder = folder
        self.name = name
    }
}

/// Set once by the module; the port checks it between steps and can ask to be told at once (to stop a process).
public final class FileToolsCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [@Sendable () -> Void] = []

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Runs every waiting handler once, outside the lock. Later calls do nothing.
    public func cancel() {
        let waiting = lock.withLock { () -> [@Sendable () -> Void] in
            guard !cancelled else { return [] }
            cancelled = true
            defer { handlers = [] }
            return handlers
        }
        waiting.forEach { $0() }
    }

    /// Runs `handler` on cancel, or at once if already cancelled.
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let now = lock.withLock { () -> Bool in
            if cancelled { return true }
            handlers.append(handler)
            return false
        }
        if now { handler() }
    }
}

public enum FileToolsError: Error, Equatable, Sendable {
    case off
    case busy
    case noInputs
    case relativePath(String)
    case tooManyInputs(Int)
    case oneImageAtATime
    case qualityOutOfRange
    case needsTwoPDFs
    case missing(String)
    case notAFile(String)
    case isFolder(String)
    case wrongType(String, expected: String)
    case alreadyFormat(String, String)
    case empty(String)
    case escapesFolder(String)
    case tooLarge(Int64)
    case duplicateName(String)
    case tooManyEntries(String)
    case tooManyPixels(String)
    case unreadable(String)
    case folderNotWritable(String)
    case noFreeName(String)
    case toolFailed(String)
    case cancelled

    public var message: String {
        switch self {
        case .off: "File tools are off. Turn them on in Settings."
        case .busy: "A file job is already running. Cancel it or wait for it to finish."
        case .noInputs: "Name at least one file: one full path per line, or separated by commas."
        case let .relativePath(path): "\(path) is not a full path. Start it with / or ~/."
        case let .tooManyInputs(count): "\(count) items named; file tools take up to \(FileToolsModule.maxInputs) at a time."
        case .oneImageAtATime: "Convert one image at a time."
        case .qualityOutOfRange: "Quality must be between 0.1 and 1."
        case .needsTwoPDFs: "Name at least two PDFs to merge."
        case let .missing(name): "\(name) does not exist."
        case let .notAFile(name): "\(name) is not a file or a folder."
        case let .isFolder(name): "\(name) is a folder. Image conversion and PDF merge take files."
        case let .wrongType(name, expected): "\(name) is not \(expected)."
        case let .alreadyFormat(name, format): "\(name) is already a \(format)."
        case let .empty(name): "\(name) is empty (0 bytes)."
        case let .escapesFolder(name): "\(name) links outside its folder, so it was not read."
        case let .tooLarge(total):
            "The items add up to \(String(format: "%.1f", Double(total) / 1e9)) GB; file tools take up to 2 GB at a time."
        case let .duplicateName(name): "Two items are named \(name), and a zip cannot hold both."
        case let .tooManyEntries(name): "\(name) holds more than \(FileToolsModule.maxFolderEntries) items."
        case let .tooManyPixels(name): "\(name) is too large to convert (over 100 million pixels)."
        case let .unreadable(name): "\(name) could not be read."
        case let .folderNotWritable(name): "Cannot write a new file in \(name)."
        case let .noFreeName(name): "Every name from \(name) up to number \(FileToolsPaths.maxOutputNames) is taken."
        case let .toolFailed(reason): "Could not finish: \(reason)"
        case .cancelled: "Cancelled."
        }
    }
}

/// Boundary to the file system. The real adapter reads named inputs and writes one new file; it never changes or
/// deletes an input.
public protocol FileToolsPort: Sendable {
    /// Facts about `url`; a path that does not exist reads as `.missing`. Throws only for a folder too big to walk,
    /// an unreadable input, or a cancel.
    func inspect(_ url: URL, cancellation: FileToolsCancellation) throws -> FileToolsInput
    /// Writes the job's output under the first free name and returns where. Leaves nothing behind when it throws,
    /// including after a cancel. `progress` takes fractions 0...1 where a tool can measure them.
    func perform(
        _ job: FileToolsJob, cancellation: FileToolsCancellation, progress: @escaping @Sendable (Double) -> Void
    ) throws -> URL
    /// Deletes an output this module wrote, used when a job finished after it was cancelled.
    func removeOutput(_ url: URL)
}
