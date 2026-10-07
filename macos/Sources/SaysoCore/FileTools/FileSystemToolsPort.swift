import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// File system adapter for file tools: `/usr/bin/ditto` for zips, ImageIO for images, PDFKit for PDFs. Inputs are
/// only read. Each output is written in a temporary folder on the same volume and then moved beside the inputs under
/// the first free name with an exclusive rename, so nothing is ever replaced and a cancel or crash leaves no partial
/// file in the user's folder.
public struct FileSystemToolsPort: FileToolsPort {
    /// About 400 MB once decoded; a 48 MP photo is well inside it, and a tiny file claiming huge dimensions is not.
    public static let defaultMaxPixels = 100_000_000
    private let maxPixels: Int
    private let maxFolderEntries: Int

    public init(maxPixels: Int = defaultMaxPixels, maxFolderEntries: Int = FileToolsModule.maxFolderEntries) {
        self.maxPixels = maxPixels
        self.maxFolderEntries = maxFolderEntries
    }

    // MARK: Inspect

    public func inspect(_ url: URL, cancellation: FileToolsCancellation) throws -> FileToolsInput {
        let fileManager = FileManager.default
        // Does not follow a link in the last component, so a link is seen as a link.
        guard let own = try? fileManager.attributesOfItem(atPath: url.path) else {
            return FileToolsInput(url: url, kind: .missing)
        }
        var escapes = false
        var resolved = url
        if own[.type] as? FileAttributeType == .typeSymbolicLink {
            guard let target = Self.canonical(url.path) else { return FileToolsInput(url: url, kind: .missing) }
            resolved = URL(fileURLWithPath: target)
            let folder = Self.canonical(url.deletingLastPathComponent().path) ?? url.deletingLastPathComponent().path
            escapes = !Self.isInside(target, folder)
        }
        let attributes = resolved == url ? own : ((try? fileManager.attributesOfItem(atPath: resolved.path)) ?? [:])
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular?:
            guard fileManager.isReadableFile(atPath: resolved.path) else { throw FileToolsError.unreadable(url.lastPathComponent) }
            return FileToolsInput(
                url: url, resolved: resolved, kind: .file, byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                contentType: Self.sniff(resolved), escapesFolder: escapes
            )
        case .typeDirectory?:
            let walk = try walk(resolved, name: url.lastPathComponent, cancellation: cancellation)
            return FileToolsInput(
                url: url, resolved: resolved, kind: .directory, byteCount: walk.bytes, escapesFolder: escapes || walk.escapes
            )
        default:
            return FileToolsInput(url: url, resolved: resolved, kind: .other, escapesFolder: escapes)
        }
    }

    /// Adds up the files in a folder and looks for links that point outside it. Links are not followed.
    private func walk(_ folder: URL, name: String, cancellation: FileToolsCancellation) throws -> (bytes: Int64, escapes: Bool) {
        let root = Self.canonical(folder.path) ?? folder.path
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        let failed = FirstError()
        guard let items = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, error in failed.keep(error); return true }
        ) else { throw FileToolsError.unreadable(name) }
        var count = 0
        var bytes: Int64 = 0
        for case let item as URL in items {
            count += 1
            guard count <= maxFolderEntries else { throw FileToolsError.tooManyEntries(name) }
            if count % 256 == 0, cancellation.isCancelled { throw FileToolsError.cancelled }
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                // A link whose target cannot be found is treated as pointing outside: it cannot be shown to stay in.
                guard let target = Self.canonical(item.path), Self.isInside(target, root) else { return (bytes, true) }
            } else if values?.isRegularFile == true {
                bytes = FileToolsModule.saturatingSum(bytes, Int64(values?.fileSize ?? 0))
            }
        }
        if failed.error != nil { throw FileToolsError.unreadable(name) }
        return (bytes, false)
    }

    /// The first bytes decide the type, so a renamed file is judged by what it holds.
    static func sniff(_ url: URL) -> FileToolsContentType {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 16)) ?? Data())
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if head.starts(with: Array("%PDF-".utf8)) { return .pdf }
        if head.count >= 12, head[4..<8].elementsEqual("ftyp".utf8),
           ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(String(decoding: head[8..<12], as: UTF8.self)) {
            return .heic
        }
        return .other
    }

    // MARK: Perform

    public func perform(
        _ job: FileToolsJob, cancellation: FileToolsCancellation, progress: @escaping @Sendable (Double) -> Void
    ) throws -> URL {
        guard !cancellation.isCancelled else { throw FileToolsError.cancelled }
        let fileManager = FileManager.default
        let scratch: URL
        do {
            scratch = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: job.folder, create: true)
        } catch {
            throw FileToolsError.folderNotWritable(job.folder.lastPathComponent)
        }
        defer { try? fileManager.removeItem(at: scratch) }
        let draft = scratch.appendingPathComponent(job.name)
        switch job.tool {
        case .zip:
            try zip(job.inputs, into: draft, scratch: scratch, cancellation: cancellation)
        case let .convertImage(format, quality):
            try convert(job.inputs[0], to: format, quality: quality, into: draft)
        case .mergePDFs:
            try merge(job.inputs, into: draft, cancellation: cancellation, progress: progress)
        }
        guard !cancellation.isCancelled else { throw FileToolsError.cancelled }
        return try Self.move(draft, into: job.folder, as: job.name)
    }

    public func removeOutput(_ url: URL) {
        // Only ever a file this port wrote; never follow a link or remove a folder.
        guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Moves the finished draft beside the inputs under the first free name. The exclusive rename fails rather than
    /// replace a file, even one created a moment ago by someone else.
    static func move(_ draft: URL, into folder: URL, as name: String) throws -> URL {
        for candidate in FileToolsPaths.outputNames(for: name) {
            let target = folder.appendingPathComponent(candidate)
            if renamex_np(draft.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            let failure = errno
            switch failure {
            case EEXIST:
                continue
            case ENOTSUP, EINVAL:
                // Volumes without exclusive rename (some USB and network drives): claim the name, then replace
                // only that empty claim.
                let claim = open(target.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
                if claim < 0, errno == EEXIST { continue }
                guard claim >= 0 else { throw error(errno, folder) }
                close(claim)
                guard rename(draft.path, target.path) == 0 else {
                    let renameFailure = errno
                    unlink(target.path)
                    throw error(renameFailure, folder)
                }
                return target
            default:
                throw error(failure, folder)
            }
        }
        throw FileToolsError.noFreeName(name)
    }

    private static func error(_ code: Int32, _ folder: URL) -> FileToolsError {
        switch code {
        case EACCES, EPERM, EROFS: .folderNotWritable(folder.lastPathComponent)
        default: .toolFailed(String(cString: strerror(code)))
        }
    }

    // MARK: Zip

    /// Leaves out resource forks, extended attributes, quarantine and ACLs, so the zip holds exactly the named items
    /// (no "._name" or "__MACOSX" entries).
    private static let dittoFlags = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl"]

    private func zip(_ inputs: [FileToolsInput], into archive: URL, scratch: URL, cancellation: FileToolsCancellation) throws {
        let source: [String]
        if inputs.count == 1, inputs[0].resolved == inputs[0].url {
            // A folder keeps its own name at the top; a file is stored on its own, without its parent folder.
            source = (inputs[0].kind == .directory ? ["--keepParent"] : []) + [inputs[0].url.path]
        } else {
            // ditto archives one source, so several items (or one reached through a link) are first gathered under
            // their own names. On APFS the copies are clones and cost no space.
            let items = scratch.appendingPathComponent("items", isDirectory: true)
            try FileManager.default.createDirectory(at: items, withIntermediateDirectories: false)
            for input in inputs {
                guard !cancellation.isCancelled else { throw FileToolsError.cancelled }
                do {
                    try FileManager.default.copyItem(at: input.resolved, to: items.appendingPathComponent(input.name))
                } catch {
                    throw FileToolsError.unreadable(input.name)
                }
            }
            source = [items.path]
        }
        try runDitto(Self.dittoFlags + source + [archive.path], errors: scratch.appendingPathComponent("ditto-errors"), cancellation: cancellation)
    }

    private func runDitto(_ arguments: [String], errors: URL, cancellation: FileToolsCancellation) throws {
        let ditto = RunningProcess()
        ditto.process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.process.arguments = arguments
        // A file, not a pipe, so a long error stream can never fill a buffer and stall ditto.
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let errorLog = try FileHandle(forWritingTo: errors)
        defer { try? errorLog.close() }
        ditto.process.standardError = errorLog
        ditto.process.standardOutput = FileHandle.nullDevice
        do {
            try ditto.process.run()
        } catch {
            throw FileToolsError.toolFailed("ditto could not start: \(error.localizedDescription)")
        }
        cancellation.onCancel { ditto.stop() }
        ditto.process.waitUntilExit()
        guard !cancellation.isCancelled else { throw FileToolsError.cancelled }
        guard ditto.process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errors, encoding: .utf8))?
                .split(whereSeparator: \.isNewline).first.map { ": " + $0.prefix(200) } ?? ""
            throw FileToolsError.toolFailed("ditto stopped with status \(ditto.process.terminationStatus)\(detail)")
        }
    }

    // MARK: Images

    private func convert(_ input: FileToolsInput, to format: FileToolsImageFormat, quality: Double, into draft: URL) throws {
        guard let source = CGImageSourceCreateWithURL(input.resolved as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw FileToolsError.unreadable(input.name) }
        // Read from the header, before anything is decoded.
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow, pixels.partialValue <= maxPixels else { throw FileToolsError.tooManyPixels(input.name) }
        guard var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw FileToolsError.unreadable(input.name) }
        if format == .jpeg, Self.hasAlpha(image) {
            image = try Self.flattenOntoWhite(image, name: input.name)
        }
        guard let destination = CGImageDestinationCreateWithURL(draft as CFURL, format.typeIdentifier as CFString, 1, nil) else {
            throw FileToolsError.toolFailed("this Mac cannot write \(format.displayName) images")
        }
        // The source's properties carry its orientation, colour profile and metadata into the new file, so the
        // image keeps its pixel size and still displays the right way up.
        var options = properties
        if format != .png { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FileToolsError.toolFailed("the \(format.displayName) image could not be written")
        }
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// JPEG has no transparency, so transparent pixels become white instead of black.
    private static func flattenOntoWhite(_ image: CGImage, name: String) throws -> CGImage {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space, let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw FileToolsError.toolFailed("not enough memory to flatten \(name)") }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flat = context.makeImage() else { throw FileToolsError.toolFailed("not enough memory to flatten \(name)") }
        return flat
    }

    // MARK: PDFs

    private func merge(
        _ inputs: [FileToolsInput], into draft: URL, cancellation: FileToolsCancellation,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let documents = try inputs.map { input -> PDFDocument in
            guard let document = PDFDocument(url: input.resolved), !document.isLocked, document.pageCount > 0 else {
                throw FileToolsError.unreadable(input.name)
            }
            return document
        }
        // Writing is the last step, so progress reaches 100% only once the file is written.
        let steps = Double(documents.reduce(0) { $0 + $1.pageCount } + 1)
        let merged = PDFDocument()
        for (document, input) in Swift.zip(documents, inputs) {
            for index in 0..<document.pageCount {
                guard !cancellation.isCancelled else { throw FileToolsError.cancelled }
                guard let page = document.page(at: index)?.copy() as? PDFPage else { throw FileToolsError.unreadable(input.name) }
                merged.insert(page, at: merged.pageCount)
                progress(Double(merged.pageCount) / steps)
            }
        }
        guard merged.write(to: draft) else { throw FileToolsError.toolFailed("the merged PDF could not be written") }
        progress(1)
    }

    // MARK: Paths

    /// The real path with every link resolved; nil when it does not exist.
    static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}

private extension FileToolsImageFormat {
    var typeIdentifier: String {
        switch self {
        case .png: UTType.png.identifier
        case .jpeg: UTType.jpeg.identifier
        case .heic: UTType.heic.identifier
        }
    }
}

/// Holds ditto so a cancel from another thread can stop it.
private final class RunningProcess: @unchecked Sendable {
    let process = Process()

    func stop() {
        if process.isRunning { process.terminate() }
    }
}

private final class FirstError: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Error?
    var error: Error? { lock.withLock { first } }
    func keep(_ error: Error) { lock.withLock { if first == nil { first = error } } }
}
