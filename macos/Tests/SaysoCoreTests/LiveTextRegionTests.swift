import Testing
@testable import SaysoCore

@Test func liveTextRegionReplacesOnlyItsOriginalSelection() throws {
    var region = try #require(LiveTextRegion(
        baseline: "Hello world!",
        selection: .init(location: 6, length: 5)
    ))

    #expect(region.expectedValue == "Hello !")
    region.replace(with: "Stevie")
    #expect(region.expectedValue == "Hello Stevie!")
    #expect(region.matches("Hello Stevie!"))
    #expect(!region.matches("Hello Stevie! edited"))
    #expect(region.rangeForInsertedText() == .init(location: 6, length: 6))
    #expect(region.value(afterReplacingWith: "Sayso") == "Hello Sayso!")
}

@Test func liveTextRegionSupportsCaretAndUnicodeBoundaries() throws {
    var region = try #require(LiveTextRegion(
        baseline: "Hi 👋",
        selection: .init(location: "Hi ".utf16.count, length: 0)
    ))

    region.replace(with: "Stevie ")
    #expect(region.expectedValue == "Hi Stevie 👋")
    #expect(region.rangeForInsertedText().length == "Stevie ".utf16.count)
    #expect(LiveTextRegion(baseline: "Hi 👋", selection: .init(location: 4, length: 0)) == nil)
}
