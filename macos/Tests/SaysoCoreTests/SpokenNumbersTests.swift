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
    #expect(SpokenNumbers.normalize("fivefifty five") == "5 55")
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
