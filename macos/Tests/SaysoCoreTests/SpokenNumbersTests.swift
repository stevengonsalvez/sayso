import Testing
@testable import SaysoCore

@Test func cardinalsBecomeDigits() {
    #expect(SpokenNumbers.normalize("five hundred and fifty five") == "555")
    #expect(SpokenNumbers.normalize("I owe twenty five dollars") == "I owe 25 dollars")
    #expect(SpokenNumbers.normalize("one thousand two hundred and three") == "1203")
    #expect(SpokenNumbers.normalize("two million") == "2000000")
    #expect(SpokenNumbers.normalize("ten minutes") == "10 minutes")
}

@Test func aLoneSmallNumberStaysAWord() {
    #expect(SpokenNumbers.normalize("one of the best") == "one of the best")
    #expect(SpokenNumbers.normalize("I have two cats") == "I have two cats")
    #expect(SpokenNumbers.normalize("I and she and one more") == "I and she and one more")
}

@Test func spokenDigitRunsKeepLeadingZeros() {
    #expect(SpokenNumbers.normalize("zero one nine two") == "0192")
    #expect(SpokenNumbers.normalize("pin is four two four two") == "pin is 4242")
}

@Test func phoneNumbersGetHyphens() {
    #expect(SpokenNumbers.normalize("call five five five zero one nine two") == "call 555-0192")
    #expect(SpokenNumbers.normalize("five five five one two three four five six seven") == "555-123-4567")
    #expect(SpokenNumbers.normalize("five hundred and fifty five zero one nine two") == "555-0192")
}

@Test func glueredTokensFromTheEngineAreSplit() {
    #expect(SpokenNumbers.normalize("fivefifty five") == "five fifty five")
    #expect(SpokenNumbers.normalize("call fivefivefive zeroonenine two") == "call 555-0192")
    #expect(SpokenNumbers.normalize("threethirty pm") == "3:30 PM")
}

@Test func clockTimesUseColonAndMeridiem() {
    #expect(SpokenNumbers.normalize("meet at three thirty pm") == "meet at 3:30 PM")
    #expect(SpokenNumbers.normalize("before three thirty on wednesday") == "before 3:30 on wednesday")
    #expect(SpokenNumbers.normalize("ten forty five a m") == "10:45 AM")
    #expect(SpokenNumbers.normalize("at seven oh five p.m.") == "at 7:05 PM")
    #expect(SpokenNumbers.normalize("see you at six pm.") == "see you at 6 PM.")
}

@Test func percentAndYears() {
    #expect(SpokenNumbers.normalize("it is twenty five percent") == "it is 25%")
    #expect(SpokenNumbers.normalize("in nineteen eighty four") == "in 1984")
    #expect(SpokenNumbers.normalize("in twenty twenty six") == "in 2026")
    #expect(SpokenNumbers.normalize("in two thousand twenty six") == "in 2026")
}

@Test func punctuationAndNonNumbersSurvive() {
    #expect(SpokenNumbers.normalize("Fifty, sixty and seventy.") == "50, 60 and 70.")
    #expect(SpokenNumbers.normalize("Someone has a tone, often.") == "Someone has a tone, often.")
    #expect(SpokenNumbers.normalize("") == "")
    #expect(SpokenNumbers.normalize("line one\nline two hundred") == "line one\nline 200")
}

@Test func smartFormatAppliesNumbersOnlyWhenAsked() {
    #expect(TranscriptCleanup.smartFormat("call me at three thirty pm") == "Call me at 3:30 PM.")
    #expect(TranscriptCleanup.smartFormat("call me at three thirty pm", formatsNumbers: false) == "Call me at three thirty pm.")
}

@Test func bareScaleWordsDoNotHangAndAreLeftAlone() {
    for text in ["a hundred people", "a thousand thanks", "about a million times", "I made $2 million",
                 "one hundred hundred", "five thousand thousand"] {
        _ = SpokenNumbers.normalize(text)
    }
    #expect(SpokenNumbers.normalize("a hundred people") == "a hundred people")
    #expect(SpokenNumbers.normalize("it was a thousand thanks") == "it was a thousand thanks")
}

@Test func theVerbAmIsNotAMeridiem() {
    #expect(SpokenNumbers.normalize("Which one am I supposed to pick") == "Which one am I supposed to pick")
    #expect(SpokenNumbers.normalize("No one am I afraid of") == "No one am I afraid of")
    #expect(SpokenNumbers.normalize("I'll be there at five thirty. Am I late?") == "I'll be there at 5:30. Am I late?")
    #expect(SpokenNumbers.normalize("It was five fifteen, am I right?") == "It was five fifteen, am I right?")
    #expect(SpokenNumbers.normalize("at six am") == "at 6 AM")
}

@Test func ordinaryNumbersAreNotMadeIntoTimesOrGluedTogether() {
    #expect(SpokenNumbers.normalize("I paid about two fifty for it") == "I paid about two fifty for it")
    #expect(SpokenNumbers.normalize("take one five minute break") == "take one five minute break")
    #expect(SpokenNumbers.normalize("the nineteen eighties") == "the nineteen eighties")
    #expect(SpokenNumbers.normalize("Tenten is a character") == "Tenten is a character")
}

@Test func spacingAndPunctuationAroundNumbersIsKept() {
    #expect(SpokenNumbers.normalize(" five five five ") == " 555 ")
    #expect(SpokenNumbers.normalize("twenty \"five\" times") == "20 \"five\" times")
    #expect(SpokenNumbers.normalize("one hundred and, five") == "100 and, five")
    #expect(SpokenNumbers.normalize("at five a.m., then") == "at 5 AM, then")
}

@Test func aHugeGluedTokenStaysBounded() {
    let glued = String(repeating: "five", count: 5000)
    #expect(SpokenNumbers.normalize(glued) == glued)
}

@Test func aLeadingZeroIsNeverDropped() {
    #expect(SpokenNumbers.normalize("zero one") == "zero one")
    #expect(SpokenNumbers.normalize("flight zero one") == "flight zero one")
    #expect(SpokenNumbers.normalize("zero twenty") == "zero twenty")
    #expect(SpokenNumbers.normalize("the code is zero five") == "the code is zero five")
}

@Test func ambiguousSmallPlusBigNumbersKeepTheirWords() {
    #expect(SpokenNumbers.normalize("the meeting is three thirty") == "the meeting is three thirty")
    #expect(SpokenNumbers.normalize("it costs seven fifty") == "it costs seven fifty")
    #expect(SpokenNumbers.normalize("nine ninety nine") == "nine ninety nine")
}

@Test func tabsAtLineEdgesAreNotDoubled() {
    let once = SpokenNumbers.normalize("\tone two three four")
    #expect(once == "\t1234")
    #expect(SpokenNumbers.normalize(once) == once)
    #expect(SpokenNumbers.normalize("five six seven\t") == "567\t")
}

@Test func aSmallNumberBeforePercentIsNeverDeleted() {
    #expect(SpokenNumbers.normalize("a five percent raise") == "a five percent raise")
    #expect(SpokenNumbers.normalize("I am one percent sure") == "I am one percent sure")
    #expect(SpokenNumbers.normalize("nine percent.") == "nine percent.")
    #expect(SpokenNumbers.normalize("three thirty percent") == "three thirty percent")
    #expect(SpokenNumbers.normalize("seven fifty percent") == "seven fifty percent")
    #expect(SpokenNumbers.normalize("it is twenty five percent.") == "it is 25%.")
}
