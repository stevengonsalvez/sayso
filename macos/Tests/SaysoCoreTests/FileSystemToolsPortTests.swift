import CryptoKit
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import SaysoCore

/// The real port on real files in a unique temporary folder per test, driven through the real module where the
/// whole flow matters. Fixtures are generated here: PNGs with CGContext and ImageIO, PDFs with PDFKit.
@Suite struct FileSystemToolsPortTests {
    // MARK: Zip

    @Test func aZipOfTwoFilesHoldsExactlyThoseFilesBesideTheFirst() async throws {
        let root = try makeRoot()
        defer { remove(root) }
        let first = try write(root, "in/first.txt", "first\n")
        let second = try write(root, "other/second.txt", "second\n")
        // An extended attribute would add a "._first.txt" entry unless the zip leaves metadata out.
        #expect(setxattr(first.path, "com.example.tag", "x", 1, 0, 0) == 0)
        let before = try hashes([first, second])

        let status = try await runReal(.zip, [first, second])

        let archive = root.appendingPathComponent("in/Archive.zip")
        #expect(status == .done(archive))
        #expect(try zipEntries(archive) == ["first.txt", "second.txt"])
        #expect(try hashes([first, second]) == before, "inputs are byte for byte the same")
        #expect(try listing(root.appendingPathComponent("in")) == ["Archive.zip", "first.txt"], "nothing else written")
    }

    @Test func aSingleFileOrFolderZipKeepsItsOwnNameAtTheTop() async throws {
        let root = try makeRoot()
        defer { remove(root) }
        let single = try write(root, "notes.txt", "notes\n")
        _ = try write(root, "Photos/sub/c.txt", "c\n")
        _ = try write(root, "Photos/d.txt", "d\n")
        let photos = root.appendingPathComponent("Photos")
        // A link that stays inside the folder is kept as a link.
        try FileManager.default.createSymbolicLink(atPath: photos.appendingPathComponent("latest").path, withDestinationPath: "d.txt")

        #expect(try await runReal(.zip, [single]) == .done(root.appendingPathComponent("notes.txt.zip")))
        #expect(try zipEntries(root.appendingPathComponent("notes.txt.zip")) == ["notes.txt"])
        #expect(try await runReal(.zip, [photos]) == .done(root.appendingPathComponent("Photos.zip")))
        #expect(try zipEntries(root.appendingPathComponent("Photos.zip")) == [
            "Photos/", "Photos/d.txt", "Photos/latest", "Photos/sub/", "Photos/sub/c.txt",
        ])
    }

    @Test func aNewOutputNeverReplacesAnExistingFile() async throws {
        let root = try makeRoot()
        defer { remove(root) }
        let first = try write(root, "a.txt", "a\n")
        let second = try write(root, "b.txt", "b\n")
        let taken = try write(root, "Archive.zip", "not a zip, and it must stay that way")
        let takenToo = try write(root, "Archive 2.zip", "also taken")
        let before = try hashes([taken, takenToo])

        #expect(try await runReal(.zip, [first, second]) == .done(root.appendingPathComponent("Archive 3.zip")))
        #expect(try hashes([taken, takenToo]) == before)
        #expect(try zipEntries(root.appendingPathComponent("Archive 3.zip")) == ["a.txt", "b.txt"])
    }

    // MARK: Images

    @Test func aPngBecomesAJpegOfTheSameSizeWithItsOrientationAndAlphaOnWhite() async throws {
        let root = try makeRoot()
        defer { remove(root) }
        let png = try makePNG(root.appendingPathComponent("picture.png"), width: 64, height: 48, orientation: 6)
        let before = try hashes([png])

        let status = try await runReal(.convertImage(.jpeg, quality: 0.9), [png])

        let jpeg = root.appendingPathComponent("picture.jpg")
        #expect(status == .done(jpeg))
        let decoded = try decode(jpeg)
        #expect(decoded.type == UTType.jpeg.identifier)
        #expect(decoded.width == 64 && decoded.height == 48, "pixel size unchanged")
        #expect(decoded.orientation == 6, "orientation kept, so it still displays upright")
        let transparent = try #require(decoded.pixel(x: 60, y: 24), "a pixel from the transparent half")
        #expect(transparent.allSatisfy { $0 >= 245 }, "transparent pixels are white, got \(transparent)")
        let opaque = try #require(decoded.pixel(x: 4, y: 24))
        #expect(abs(Int(opaque[0]) - 51) < 12 && abs(Int(opaque[2]) - 153) < 12, "opaque colour kept, got \(opaque)")
        #expect(try hashes([png]) == before)
    }

    @Test func imagesConvertBetweenPngJpegAndHeic() async throws {
        let root = try makeRoot()
        defer { remove(root) }
        let png = try makePNG(root.appendingPathComponent("shot.png"), width: 40, height: 30, orientation: nil)
        #expect(try await runReal(.convertImage(.heic, quality: 0.8), [png]) == .done(root.appendingPathComponent("shot.heic")))
        let heic = try decode(root.appendingPathComponent("shot.heic"))
        #expect(heic.type == UTType.heic.identifier && heic.width == 40 && heic.height == 30)

        // shot.png is still there, so the PNG made from the HEIC takes the next free name.
        #expect(try await runReal(.convertImage(.png, quality: 1), [root.appendingPathComponent("shot.heic")]) == .done(root.appendingPathComponent("shot 2.png")))
        let back = try decode(root.appendingPathComponent("shot 2.png"))
        #expect(back.type == UTType.png.identifier && back.width == 40 && back.height == 30)
    }

    @Test func qualityChangesTheJpegSize() async throws {
        let root = try makeRoot()
        defer { remove(root) }
        let low = try makePNG(root.appendingPathComponent("low/noise.png"), width: 256, height: 256, orientation: nil, noise: true)
        let high = try makePNG(root.appendingPathComponent("high/noise.png"), width: 256, height: 256, orientation: nil, noise: true)
        _ = try await runReal(.convertImage(.jpeg, quality: 0.1), [low])
        _ = try await runReal(.convertImage(.jpeg, quality: 1), [high])
        let lowSize = try size(root.appendingPathComponent("low/noise.jpg"))
        let highSize = try size(root.appendingPathComponent("high/noise.jpg"))
        #expect(lowSize * 2 < highSize, "quality 0.1 gave \(lowSize) bytes, 1.0 gave \(highSize)")
    }

    @Test func anImageWithTooManyPixelsIsRefusedBeforeItIsDecoded() async throws {
        let root = try makeRoot()
        defer { remove(root) }
        let png = try makePNG(root.appendingPathComponent("wide.png"), width: 40, height: 20, orientation: nil)
        let status = try await runReal(.convertImage(.jpeg, quality: 0.8), [png], port: FileSystemToolsPort(maxPixels: 799))
        #expect(status == .failed(.tooManyPixels("wide.png")))
        #expect(try listing(root) == ["wide.png"])
    }

    // MARK: PDFs

    @Test func aMergeHoldsEveryPageInTheOrderNamed() async throws {
        let root = try makeRoot()
        defer { remove(root) }
        let first = try makePDF(root.appendingPathComponent("first.pdf"), widths: [100, 200])
        let second = try makePDF(root.appendingPathComponent("second.pdf"), widths: [300])
        let before = try hashes([first, second])

        #expect(try await runReal(.mergePDFs, [first, second]) == .done(root.appendingPathComponent("Merged.pdf")))
        #expect(try pageWidths(root.appendingPathComponent("Merged.pdf")) == [100, 200, 300])
        #expect(try await runReal(.mergePDFs, [second, first]) == .done(root.appendingPathComponent("Merged 2.pdf")))
        #expect(try pageWidths(root.appendingPathComponent("Merged 2.pdf")) == [300, 100, 200])
        #expect(try hashes([first, second]) == before)
    }

    @Test func aCancelInTheMiddleOfAMergeLeavesNothingBehind() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let first = try makePDF(root.appendingPathComponent("long.pdf"), widths: Array(repeating: 100, count: 300))
        let second = try makePDF(root.appendingPathComponent("short.pdf"), widths: [100])
        let port = FileSystemToolsPort()
        let cancellation = FileToolsCancellation()
        let job = try plan(port, .mergePDFs, [first, second], name: "Merged.pdf")
        let seen = Progress()

        #expect(throws: FileToolsError.cancelled) {
            try port.perform(job, cancellation: cancellation) { fraction in
                seen.record(fraction)
                if fraction >= 0.3 { cancellation.cancel() }
            }
        }
        #expect(seen.last < 0.5, "stopped soon after the cancel, at \(seen.last)")
        #expect(try listing(root) == ["long.pdf", "short.pdf"])
    }

    // MARK: Cancel and clean up

    @Test func aCancelledZipStopsDittoAndLeavesNothingBehind() throws {
        let root = try makeRoot()
        defer { remove(root) }
        var noise = Data(count: 64 * 1024 * 1024)
        noise.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let big = root.appendingPathComponent("noise.bin")
        try noise.write(to: big)
        let port = FileSystemToolsPort()
        let cancellation = FileToolsCancellation()
        let job = try plan(port, .zip, [big], name: "noise.bin.zip")
        // A thread of its own: in the full parallel suite a block queued on a busy global queue arrived only after
        // ditto had finished (7.7 s), so the cancel never happened.
        Thread {
            Thread.sleep(forTimeInterval: 0.1)
            cancellation.cancel()
        }.start()

        let started = Date()
        #expect(throws: FileToolsError.cancelled) { try port.perform(job, cancellation: cancellation) { _ in } }
        #expect(Date().timeIntervalSince(started) < 5, "ditto was stopped, not waited for")
        #expect(try listing(root) == ["noise.bin"])
    }

    @Test func aJobCancelledBeforeItStartsWritesNothing() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let file = try write(root, "a.txt", "a\n")
        let port = FileSystemToolsPort()
        let cancellation = FileToolsCancellation()
        cancellation.cancel()
        #expect(throws: FileToolsError.cancelled) {
            try port.perform(try plan(port, .zip, [file], name: "a.txt.zip"), cancellation: cancellation) { _ in }
        }
        #expect(try listing(root) == ["a.txt"])
    }

    @Test func removeOutputDeletesTheFile() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let output = try write(root, "Archive.zip", "x")
        FileSystemToolsPort().removeOutput(output)
        #expect(try listing(root).isEmpty)
    }

    @Test func aFolderThatCannotBeWrittenIsNamed() async throws {
        let root = try makeRoot()
        defer { remove(root) }
        let locked = root.appendingPathComponent("Locked")
        let file = try write(root, "Locked/a.txt", "a\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        #expect(try await runReal(.zip, [file]) == .failed(.folderNotWritable("Locked")))
        #expect(try listing(locked) == ["a.txt"])
    }

    // MARK: Refusals on real files

    @Test func realInputsAreRefusedForTheRightReason() async throws {
        let root = try makeRoot()
        defer { remove(root) }
        let fm = FileManager.default
        let text = try write(root, "in/notes.txt", "hello\n")
        let fakePNG = try write(root, "in/fake.png", "not an image")
        let empty = try write(root, "in/empty.txt", "")
        let pdf = try makePDF(root.appendingPathComponent("in/one.pdf"), widths: [100])
        let photo = try makePNG(root.appendingPathComponent("in/photo.png"), width: 8, height: 8, orientation: nil)
        let secret = try write(root, "elsewhere/secret.png", "outside")
        let link = root.appendingPathComponent("in/link.png")
        try fm.createSymbolicLink(at: link, withDestinationURL: secret)
        _ = try write(root, "in/Shared/a.txt", "a\n")
        try fm.createSymbolicLink(at: root.appendingPathComponent("in/Shared/out"), withDestinationURL: secret)
        let pipe = root.appendingPathComponent("in/pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let sparse = root.appendingPathComponent("in/huge.bin")
        #expect(fm.createFile(atPath: sparse.path, contents: Data("x".utf8)))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 2_100_000_000)
        try handle.close()
        let jpeg = FileToolsTool.convertImage(.jpeg, quality: 0.8)

        #expect(try await runReal(.zip, [root.appendingPathComponent("in/gone.txt")]) == .failed(.missing("gone.txt")))
        #expect(try await runReal(jpeg, [root.appendingPathComponent("in/Shared")]) == .failed(.isFolder("Shared")))
        #expect(try await runReal(.mergePDFs, [pdf, root.appendingPathComponent("in/Shared")]) == .failed(.isFolder("Shared")))
        #expect(try await runReal(jpeg, [fakePNG]) == .failed(.wrongType("fake.png", expected: "a PNG, JPEG or HEIC image")))
        #expect(try await runReal(.mergePDFs, [pdf, photo]) == .failed(.wrongType("photo.png", expected: "a PDF")))
        #expect(try await runReal(.zip, [text, empty]) == .failed(.empty("empty.txt")))
        #expect(try await runReal(jpeg, [link]) == .failed(.escapesFolder("link.png")))
        #expect(try await runReal(.zip, [root.appendingPathComponent("in/Shared")]) == .failed(.escapesFolder("Shared")))
        #expect(try await runReal(.zip, [pipe]) == .failed(.notAFile("pipe")))
        #expect(try await runReal(.zip, [text, sparse]) == .failed(.tooLarge(2_100_000_006)))
        #expect(try await runReal(.zip, Array(repeating: text, count: 201)) == .failed(.tooManyInputs(201)))
        #expect(try listing(root.appendingPathComponent("in")) == [
            "Shared", "empty.txt", "fake.png", "huge.bin", "link.png", "notes.txt", "one.pdf", "photo.png", "pipe",
        ], "no refusal wrote anything")
    }

    @Test func inspectReadsTheTypeFromTheContentAndSizesAFolder() throws {
        let root = try makeRoot()
        defer { remove(root) }
        let port = FileSystemToolsPort()
        let none = FileToolsCancellation()
        let png = try makePNG(root.appendingPathComponent("named.txt"), width: 4, height: 4, orientation: nil)
        let pdf = try makePDF(root.appendingPathComponent("doc.bin"), widths: [100])
        _ = try write(root, "Folder/a.txt", "12345")
        _ = try write(root, "Folder/sub/b.txt", "123")

        #expect(try port.inspect(png, cancellation: none).contentType == .png)
        #expect(try port.inspect(pdf, cancellation: none).contentType == .pdf)
        let folder = try port.inspect(root.appendingPathComponent("Folder"), cancellation: none)
        #expect(folder.kind == .directory)
        #expect(folder.byteCount == 8)
        #expect(!folder.escapesFolder)
        #expect(try port.inspect(root.appendingPathComponent("nothing"), cancellation: none).kind == .missing)
        // A link inside its own folder is followed and allowed.
        let inside = root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: png)
        let followed = try port.inspect(inside, cancellation: none)
        #expect(followed.kind == .file && followed.contentType == .png && !followed.escapesFolder)
        #expect(followed.resolved.lastPathComponent == "named.txt")
    }

    @Test func aFolderWithTooManyItemsIsRefusedWithoutWalkingOn() throws {
        let root = try makeRoot()
        defer { remove(root) }
        for index in 0..<5 { _ = try write(root, "Many/\(index).txt", "x") }
        #expect(throws: FileToolsError.tooManyEntries("Many")) {
            try FileSystemToolsPort(maxFolderEntries: 3).inspect(root.appendingPathComponent("Many"), cancellation: FileToolsCancellation())
        }
    }
}

// MARK: Helpers

private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [Double] = []
    var last: Double { lock.withLock { fractions.last ?? 0 } }
    func record(_ fraction: Double) { lock.withLock { fractions.append(fraction) } }
}

private struct Decoded {
    let type: String?
    let width: Int
    let height: Int
    let orientation: Int?
    let image: CGImage

    /// RGBA of one pixel, drawn into an sRGB buffer; y counts from the top.
    func pixel(x: Int, y: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let offset = (y * width + x) * 4
        return Array(bytes[offset..<offset + 4])
    }
}

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileSystemToolsPortTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // The canonical path, so names compare the same however the temporary folder is reached.
    return URL(fileURLWithPath: root.resolvingSymlinksInPath().path)
}

private func remove(_ root: URL) { try? FileManager.default.removeItem(at: root) }

private func write(_ root: URL, _ relative: String, _ text: String) throws -> URL {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
}

/// Left half opaque rgb(51, 102, 153), right half fully transparent; `noise` fills it with random opaque pixels.
private func makePNG(_ url: URL, width: Int, height: Int, orientation: Int?, noise: Bool = false) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    if noise {
        var generator = SystemRandomNumberGenerator()
        for x in 0..<width {
            for y in 0..<height {
                context.setFillColor(
                    red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                    blue: .random(in: 0...1, using: &generator), alpha: 1
                )
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    } else {
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    }
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

/// One page per width, each 300 points high, made with PDFKit.
private func makePDF(_ url: URL, widths: [Int]) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let document = PDFDocument()
    for (index, width) in widths.enumerated() {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: width, height: 300), for: .mediaBox)
        document.insert(page, at: index)
    }
    #expect(document.write(to: url))
    return url
}

private func pageWidths(_ url: URL) throws -> [Int] {
    let document = try #require(PDFDocument(url: url))
    return (0..<document.pageCount).compactMap { document.page(at: $0).map { Int($0.bounds(for: .mediaBox).width) } }
}

private func decode(_ url: URL) throws -> Decoded {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "\(url.lastPathComponent) exists")
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil), "\(url.lastPathComponent) decodes")
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    return Decoded(
        type: CGImageSourceGetType(source) as String?, width: image.width, height: image.height,
        orientation: properties[kCGImagePropertyOrientation] as? Int, image: image
    )
}

private func hashes(_ urls: [URL]) throws -> [String] {
    try urls.map { SHA256.hash(data: try Data(contentsOf: $0)).map { String(format: "%02x", $0) }.joined() }
}

private func size(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
}

private func listing(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

/// Entry names from `/usr/bin/unzip -l`, which prints a dashed line above and below the entries.
private func zipEntries(_ archive: URL) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-l", archive.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "unzip -l reads \(archive.lastPathComponent)")
    let lines = output.components(separatedBy: "\n")
    let dashes = lines.indices.filter { lines[$0].hasPrefix("---------") }
    guard dashes.count >= 2 else {
        Issue.record("unexpected unzip output: \(output)")
        return []
    }
    return lines[(dashes[0] + 1)..<dashes[1]].map { line in
        let columns = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        // The last split keeps the spaces before the name.
        return columns.count == 4 ? String(columns[3].drop { $0 == " " }) : line
    }.sorted()
}

/// Inspects and validates real inputs the way the module does, for tests that drive the port directly.
private func plan(_ port: FileSystemToolsPort, _ tool: FileToolsTool, _ urls: [URL], name: String) throws -> FileToolsJob {
    let inputs = try urls.map { try port.inspect($0, cancellation: FileToolsCancellation()) }
    try FileToolsModule.validate(tool, inputs)
    return FileToolsJob(tool: tool, inputs: inputs, folder: urls[0].deletingLastPathComponent(), name: name)
}

/// Runs one job through the real module, the real port and a real background worker, and returns how it ended.
private func runReal(
    _ tool: FileToolsTool, _ urls: [URL], port: FileSystemToolsPort = FileSystemToolsPort()
) async throws -> FileToolsStatus {
    let module = FileToolsModule(
        port: port, scheduler: SaysoDispatchScheduler(queue: DispatchQueue(label: "file-tools-port-tests.notice")),
        worker: .serial(label: "file-tools-port-tests")
    )
    let host = SaysoModuleHost(modules: [module])
    host.enable("file-tools")
    defer { host.disable("file-tools") }
    if let refused = module.run(tool, paths: urls.map(\.path).joined(separator: "\n")) { return .failed(refused) }
    for _ in 0..<3000 {
        switch module.status {
        case .done, .failed, .cancelled: return module.status
        case .idle, .running, .cancelling: try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    Issue.record("the job did not finish within 30 s: \(module.status)")
    return module.status
}
