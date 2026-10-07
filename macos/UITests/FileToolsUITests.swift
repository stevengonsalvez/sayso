import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest

/// File tools in the Notch & HUD pane: zip, image conversion and PDF merge on files this test generates in a unique
/// folder under its own temporary directory. The runner is not sandboxed (see `SaysoUITests.entitlements`), so that
/// folder is the user's temporary directory, which the app can read and write without asking for another app's data.
/// Add files and Reveal in Finder are never pressed: one opens a panel, the other activates Finder.
final class FileToolsUITests: XCTestCase {
    var app: XCUIApplication!
    var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sayso-file-tools-\(UUID().uuidString)", isDirectory: true)
        // A sandboxed runner would put this inside its container, and the app reaching into it can make macOS ask
        // the user for access to another app's data. Stop before launching anything.
        XCTAssertFalse(folder.path.contains("/Library/Containers/"), "the runner must not be sandboxed: \(folder.path)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let path = ProcessInfo.processInfo.environment["SAYSO_APP_PATH"] ?? "\(NSHomeDirectory())/.artifacts/Sayso Notch.app"
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchArguments = ["--ui-test-fresh-settings"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testZipOfTwoFilesHoldsExactlyThoseFiles() throws {
        let first = try write("first.txt", Data("first file\n".utf8))
        let second = try write("second.txt", Data("second file\n".utf8))
        let hashes = try hash([first, second])

        openNotchPane()
        enterPaths([first, second])
        press("file-tools-zip")
        let status = waitForDone()

        let archive = folder.appendingPathComponent("Archive.zip")
        XCTAssertTrue(status.contains("Archive.zip"), "status names the output, got \(status)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path), "Archive.zip beside the inputs")
        XCTAssertEqual(try zipEntries(archive), ["first.txt", "second.txt"])
        XCTAssertEqual(try hash([first, second]), hashes, "inputs unchanged")
    }

    func testAPngConvertsToAJpegThatDecodesAtTheSameSize() throws {
        let png = try makePNG("picture.png", width: 64, height: 48)
        let hashes = try hash([png])

        openNotchPane()
        enterPaths([png])
        press("file-tools-image-jpeg")
        let status = waitForDone()

        let jpeg = folder.appendingPathComponent("picture.jpg")
        XCTAssertTrue(status.contains("picture.jpg"), "status names the output, got \(status)")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpeg as CFURL, nil), "picture.jpg exists")
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "picture.jpg decodes")
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        XCTAssertEqual(try hash([png]), hashes, "input unchanged")
    }

    func testTwoPdfsMergeIntoOneWithEveryPage() throws {
        let one = try makePDF("one.pdf", pages: 2)
        let two = try makePDF("two.pdf", pages: 1)
        let hashes = try hash([one, two])

        openNotchPane()
        enterPaths([one, two])
        press("file-tools-pdf-merge")
        let status = waitForDone()

        let merged = folder.appendingPathComponent("Merged.pdf")
        XCTAssertTrue(status.contains("Merged.pdf"), "status names the output, got \(status)")
        let document = try XCTUnwrap(PDFDocument(url: merged), "Merged.pdf exists and opens")
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual(try hash([one, two]), hashes, "inputs unchanged")
    }

    /// The pane's off notice and disabled buttons come from the module's state, not the setting, so this fails if the
    /// setting stops reaching the module.
    func testTheToggleIsOnByDefaultAndOffStopsTheTools() throws {
        let toggle = openSettingsToggle()
        XCTAssertEqual(isOn(toggle), true, "on by default (value: \(String(describing: toggle.value)))")
        toggle.click()
        XCTAssertEqual(isOn(toggle), false, "the click turned the throwaway setting off (value: \(String(describing: toggle.value)))")

        openNotchPane()
        let off = element("file-tools-off")
        reveal(off)
        XCTAssertTrue(off.waitForExistence(timeout: 5), "the pane says file tools are off")
        XCTAssertFalse(element("file-tools-zip").isEnabled, "nothing to run while off")

        let again = openSettingsToggle()
        again.click()
        XCTAssertEqual(isOn(again), true, "the click turned the throwaway setting back on (value: \(String(describing: again.value)))")
        openNotchPane()
        let zip = element("file-tools-zip")
        reveal(zip)
        XCTAssertTrue(zip.waitForExistence(timeout: 5), "zip button")
        XCTAssertTrue(zip.isEnabled, "zip is offered again")
        XCTAssertFalse(element("file-tools-off").exists, "the off notice is gone")
    }

    // MARK: Fixtures

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A half transparent PNG drawn with CGContext and written with ImageIO.
    private func makePNG(_ name: String, width: Int, height: Int) throws -> URL {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let url = folder.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "wrote \(name)")
        return url
    }

    private func makePDF(_ name: String, pages: Int) throws -> URL {
        let document = PDFDocument()
        for index in 0..<pages {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 200 + index * 10, height: 300), for: .mediaBox)
            document.insert(page, at: index)
        }
        let url = folder.appendingPathComponent(name)
        XCTAssertTrue(document.write(to: url), "wrote \(name)")
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, pages, "\(name) has \(pages) pages")
        return url
    }

    private func hash(_ urls: [URL]) throws -> [String] {
        try urls.map { SHA256.hash(data: try Data(contentsOf: $0)).map { String(format: "%02x", $0) }.joined() }
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
        XCTAssertEqual(process.terminationStatus, 0, "unzip -l reads the archive")
        let lines = output.components(separatedBy: "\n")
        let dashes = lines.indices.filter { lines[$0].hasPrefix("---------") }
        guard dashes.count >= 2 else { XCTFail("unexpected unzip output: \(output)"); return [] }
        return lines[(dashes[0] + 1)..<dashes[1]].map { line in
            // "   Length      Date    Time    Name": the name is everything after the third column.
            let columns = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            return columns.count == 4 ? String(columns[3]) : line
        }.sorted()
    }

    // MARK: App

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func openNotchPane() {
        let tab = element("studio-tab-notch")
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Notch & HUD")
        tab.click()
    }

    /// Scrolls the Notch & HUD pane straight down until `element` can be clicked. The pane is long and the file tools
    /// sit near its end; XCUITest's own scroll-to-visible also scrolls sideways and has left rows unclickable.
    private func reveal(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) exists")
        let pane = app.scrollViews["studio-pane-notch"]
        for _ in 0..<40 where !element.isHittable {
            pane.scroll(byDeltaX: 0, deltaY: -100)
        }
        XCTAssertTrue(element.isHittable, "can be clicked, frame \(element.frame)")
    }

    /// Replaces the field's text with the paths, comma separated.
    private func enterPaths(_ urls: [URL]) {
        let field = element("file-tools-paths")
        reveal(field)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(urls.map(\.path).joined(separator: ", "))
    }

    private func press(_ identifier: String) {
        let button = element(identifier)
        reveal(button)
        XCTAssertTrue(button.isEnabled, "\(identifier) is offered")
        button.click()
    }

    /// Waits for the status to read done and returns it; fails at once with the text if it reads failed.
    private func waitForDone() -> String {
        let status = element("file-tools-status")
        XCTAssertTrue(status.waitForExistence(timeout: 5), "file tools status")
        let finished = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            let text = self.text(of: element)
            return text.hasPrefix("Done") || text.hasPrefix("Failed")
        }
        expectation(for: finished, evaluatedWith: status)
        waitForExpectations(timeout: 30)
        let text = text(of: status)
        XCTAssertTrue(text.hasPrefix("Done"), "status reads done, got \(text)")
        return text
    }

    private func openSettingsToggle() -> XCUIElement {
        let tab = element("studio-tab-settings")
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "sidebar tab for Settings")
        tab.click()
        let toggle = element("settings-file-tools-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "File tools toggle in Settings")
        return toggle
    }

    /// SwiftUI exposes a Text as its value or its label depending on the macOS release.
    private func text(of element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    /// nil means unreadable, so the test cannot pass by failing to read the value.
    private func isOn(_ toggle: XCUIElement) -> Bool? {
        switch toggle.value {
        case let number as NSNumber: number.boolValue
        case let text as String where text == "0" || text == "1": text == "1"
        default: nil
        }
    }
}
