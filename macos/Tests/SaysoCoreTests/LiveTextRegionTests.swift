import Testing
@testable import SaysoCore

@Test func directInsertionRequiresObservedValueChange() {
    #expect(TextInsertionVerification.changed(previous: "", current: "hello"))
    #expect(!TextInsertionVerification.changed(previous: "", current: ""))
    #expect(!TextInsertionVerification.changed(previous: nil, current: "hello"))
    #expect(!TextInsertionVerification.changed(previous: "", current: nil))
}

@Test func liveTextRegionReplacesOnlyItsOriginalSelection() throws {
    var region = try #require(LiveTextRegion(
        baseline: "Hello world!",
        selection: .init(location: 6, length: 5)
    ))

    #expect(region.expectedValue == "Hello world!")
    #expect(region.matches("Hello world!"))
    region.replace(with: "Stevie")
    #expect(region.expectedValue == "Hello Stevie!")
    #expect(region.matches("Hello Stevie!"))
    #expect(!region.matches("Hello Stevie! edited"))
    #expect(region.rangeForInsertedText() == .init(location: 6, length: 6))
    #expect(region.replacementRange == .init(location: 6, length: 6))
    #expect(region.value(afterReplacingWith: "Sayso") == "Hello Sayso!")
    region.restore()
    #expect(region.expectedValue == "Hello world!")
    #expect(region.replacementRange == .init(location: 6, length: 5))
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

@Test func liveInsertionSafetyRequiresUnchangedValueAndSelection() throws {
    let region = try #require(LiveTextRegion(
        baseline: "Hello world!",
        selection: .init(location: 6, length: 5)
    ))

    #expect(LiveInsertionSafety.allowsReplacement(
        currentValue: "Hello world!",
        currentSelection: .init(location: 6, length: 5),
        region: region,
        expectedSelection: .init(location: 6, length: 5)
    ))
    #expect(!LiveInsertionSafety.allowsReplacement(
        currentValue: "Hello changed!",
        currentSelection: .init(location: 6, length: 5),
        region: region,
        expectedSelection: .init(location: 6, length: 5)
    ))
    #expect(!LiveInsertionSafety.allowsReplacement(
        currentValue: "Hello world!",
        currentSelection: .init(location: 0, length: 0),
        region: region,
        expectedSelection: .init(location: 6, length: 5)
    ))

    var inserted = region
    inserted.replace(with: "Sayso")
    #expect(LiveInsertionSafety.allowsReplacement(
        currentValue: "Hello Sayso!",
        currentSelection: .init(location: 11, length: 0),
        region: inserted,
        expectedSelection: .init(location: 11, length: 0)
    ))
}
