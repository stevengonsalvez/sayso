import AppKit
import Testing
@testable import SaysoCore

private func color(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> ColorPickerColor {
    ColorPickerColor(red: red, green: green, blue: blue)
}

@Suite struct ColorPickerConversionTests {
    @Test func hexIsHashAndSixUppercaseDigits() {
        #expect(color(0x33, 0x66, 0x99).hex == "#336699")
        #expect(color(10, 171, 205).hex == "#0AABCD", "leading zeros kept, letters upper case")
        #expect(color(0, 0, 0).hex == "#000000")
        #expect(color(255, 255, 255).hex == "#FFFFFF")
    }

    @Test func rgbListsTheThreeChannels() {
        #expect(color(51, 102, 153).rgb == "rgb(51, 102, 153)")
        #expect(color(0, 0, 0).rgb == "rgb(0, 0, 0)")
    }

    @Test func hslIsRoundedToWholeDegreesAndPercents() {
        #expect(color(51, 102, 153).hsl == ColorPickerHSL(hue: 210, saturation: 50, lightness: 40))
        #expect(color(51, 102, 153).hsl.text == "hsl(210, 50%, 40%)")
        #expect(color(255, 0, 0).hsl == ColorPickerHSL(hue: 0, saturation: 100, lightness: 50))
        #expect(color(0, 255, 0).hsl == ColorPickerHSL(hue: 120, saturation: 100, lightness: 50))
        #expect(color(0, 0, 255).hsl == ColorPickerHSL(hue: 240, saturation: 100, lightness: 50))
        #expect(color(255, 0, 4).hsl.hue == 359)
    }

    @Test func aHueThatRoundsUpTo360ReadsZero() {
        #expect(color(255, 0, 1).hsl.hue == 0, "359.76 degrees rounds to 360, which is 0")
    }

    @Test func greyHasHueZeroAndSaturationZero() {
        #expect(color(128, 128, 128).hsl == ColorPickerHSL(hue: 0, saturation: 0, lightness: 50))
        #expect(color(255, 255, 255).hsl == ColorPickerHSL(hue: 0, saturation: 0, lightness: 100))
        #expect(color(0, 0, 0).hsl == ColorPickerHSL(hue: 0, saturation: 0, lightness: 0))
    }

    @Test func everyColourGivesAHueBelow360AndPercentsWithin0To100() {
        for red in stride(from: 0, through: 255, by: 5) {
            for green in stride(from: 0, through: 255, by: 5) {
                for blue in stride(from: 0, through: 255, by: 5) {
                    let hsl = color(UInt8(red), UInt8(green), UInt8(blue)).hsl
                    guard (0...359).contains(hsl.hue), (0...100).contains(hsl.saturation), (0...100).contains(hsl.lightness)
                    else {
                        Issue.record("rgb(\(red), \(green), \(blue)) gave \(hsl.text)")
                        return
                    }
                }
            }
        }
    }

    @Test func eachFormatHasItsText() {
        let picked = color(51, 102, 153)
        #expect(ColorPickerFormat.allCases == [.hex, .rgb, .hsl])
        #expect(ColorPickerFormat.allCases.map { picked.text($0) } == ["#336699", "rgb(51, 102, 153)", "hsl(210, 50%, 40%)"])
    }

    @Test func srgbComponentsAreRoundedAndClampedAndNotANumberReadsZero() {
        #expect(ColorPickerColor(srgbRed: 0.2, green: 0.4, blue: 0.6) == color(51, 102, 153))
        #expect(ColorPickerColor(srgbRed: 1.2, green: -0.1, blue: .nan) == color(255, 0, 0))
        #expect(ColorPickerColor(srgbRed: .infinity, green: -.infinity, blue: 0.5) == color(255, 0, 128))
    }
}

@Suite struct ColorPickerParserTests {
    @Test func shortAndLongHexAreRead() {
        #expect(ColorPickerColor.parse("#abc") == color(0xAA, 0xBB, 0xCC))
        #expect(ColorPickerColor.parse("#aabbcc") == color(0xAA, 0xBB, 0xCC))
        #expect(ColorPickerColor.parse("#AbC") == color(0xAA, 0xBB, 0xCC), "either case")
        #expect(ColorPickerColor.parse("  #336699\n") == color(0x33, 0x66, 0x99), "surrounding space is trimmed")
    }

    @Test func rgbIsReadWithCommasOrSpaces() {
        #expect(ColorPickerColor.parse("rgb(1,2,3)") == color(1, 2, 3))
        #expect(ColorPickerColor.parse("rgb(1 2 3)") == color(1, 2, 3))
        #expect(ColorPickerColor.parse("RGB( 51 , 102 , 153 )") == color(51, 102, 153))
        #expect(ColorPickerColor.parse("rgb(1.4, 2.6, 254.5)") == color(1, 3, 255), "fractions round to the nearest")
    }

    @Test func hslIsReadAndConvertedToRgb() {
        #expect(ColorPickerColor.parse("hsl(10 50% 50%)") == color(191, 85, 64))
        #expect(ColorPickerColor.parse("hsl(210, 50%, 40%)") == color(51, 102, 153))
        #expect(ColorPickerColor.parse("hsl(0 0% 100%)") == color(255, 255, 255))
        #expect(ColorPickerColor.parse("hsl(120 100 25)") == color(0, 128, 0), "the percent sign may be left out")
    }

    @Test func outOfRangeNumbersAreClampedAndHueWrapsAround() {
        #expect(ColorPickerColor.parse("rgb(300, -5, 10)") == color(255, 0, 10))
        #expect(ColorPickerColor.parse("hsl(-350 50% 50%)") == ColorPickerColor.parse("hsl(10 50% 50%)"))
        #expect(ColorPickerColor.parse("hsl(370 50% 50%)") == ColorPickerColor.parse("hsl(10 50% 50%)"))
        #expect(ColorPickerColor.parse("hsl(10 150% 50%)") == ColorPickerColor.parse("hsl(10 100% 50%)"))
        #expect(ColorPickerColor.parse("hsl(10 50% -10%)") == color(0, 0, 0))
    }

    @Test func malformedInputIsRejected() {
        let rejected = [
            "", "   ", "#", "#ab", "#abcd", "#aabbccdd", "#ggg", "336699", "red", "##abc",
            "rgb(1,2)", "rgb(1,2,3,4)", "rgb(1,2,x)", "rgb(1%,2,3)", "rgb(1,,2)", "rgb(1, 2 3)", "rgb 1 2 3", "rgb(1,2,3",
            "rgb(nan,1,2)", "rgb(inf,1,2)", "rgb(1e3,1,2)", "rgb(0x10,1,2)", "rgb(-,1,2)", "rgb(1.,2,3)", "rgb(.5.5,2,3)",
            "hsl(10 50% 50%", "hsl(10 50%% 50%)", "hsl(10% 50% 50%)", "hsl(10 50% 50%) x", "rgb(1,2,3)hsl(1,2,3)",
        ]
        for input in rejected {
            #expect(ColorPickerColor.parse(input) == nil, "\(input.debugDescription) is not a colour")
        }
    }

    @Test func inputLongerThanTheLimitIsRejectedBeforeParsing() {
        #expect(ColorPickerColor.maxInputLength == 64)
        let padded = String(repeating: " ", count: ColorPickerColor.maxInputLength) + "#abc"
        #expect(ColorPickerColor.parse(padded) == nil, "the limit counts the input as given, before trimming")
        let started = Date()
        #expect(ColorPickerColor.parse("rgb(" + String(repeating: "0", count: 100_000) + "1, 2, 3)") == nil)
        #expect(Date().timeIntervalSince(started) < 0.2)
        let atLimit = "rgb(" + String(repeating: " ", count: ColorPickerColor.maxInputLength - "rgb(1,2,3)".count) + "1,2,3)"
        #expect(atLimit.utf8.count == ColorPickerColor.maxInputLength)
        #expect(ColorPickerColor.parse(atLimit) == color(1, 2, 3), "exactly at the limit is still read")
    }

    @Test func everyFormattedColourParsesBackToItself() {
        for red in stride(from: 0, through: 255, by: 15) {
            for green in stride(from: 0, through: 255, by: 15) {
                for blue in stride(from: 0, through: 255, by: 15) {
                    let original = color(UInt8(red), UInt8(green), UInt8(blue))
                    #expect(ColorPickerColor.parse(original.hex) == original)
                    #expect(ColorPickerColor.parse(original.rgb) == original)
                }
            }
        }
    }
}
