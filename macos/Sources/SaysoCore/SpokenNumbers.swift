import Foundation

/// Turns spoken numbers into digits: cardinals ("five hundred and fifty five" -> "555"), digit runs
/// ("zero one nine two" -> "0192"), phone shapes, clock times ("three thirty pm" -> "3:30 PM"),
/// percent and years. Deterministic, no model, English only.
///
/// Rules a reader should know: a lone number below ten stays a word ("I have two cats"); hour and minute without am or pm only become a time after a word such as
/// "at" or "before"; the speech engine sometimes glues number words together ("threethirty"), so
/// glued tokens made only of number words are split first.
public enum SpokenNumbers {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000]
    private static let vocabulary: [String] = (Array(units.keys) + Array(tens.keys) + Array(scales.keys))
        .sorted { $0.count > $1.count }
    private static let timeLeaders: Set<String> = ["at", "by", "before", "until", "till", "from"]
    private static let decadeWords: Set<String> = ["twenties", "thirties", "forties", "fifties", "sixties", "seventies", "eighties", "nineties", "hundreds", "thousands", "millions"]

    private struct Token {
        var lead = ""
        var core: String
        var trail = ""
        var lower: String { core.lowercased() }
        var text: String { lead + core + trail }
    }

    public static func normalize(_ text: String) -> String {
        guard text.rangeOfCharacter(from: .letters) != nil else { return text }
        return text.components(separatedBy: "\n").map(normalizeLine).joined(separator: "\n")
    }

    private static func normalizeLine(_ line: String) -> String {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).flatMap { split(token(String($0))) }
        guard tokens.contains(where: { isNumberWord($0.lower) || $0.lower == "oh" }) else { return line }
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let trailing = String(line.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            if let time = parseTime(tokens, at: i, previous: out.last?.lowercased()) {
                out.append(time.text)
                i += time.consumed
                continue
            }
            if isNumberWord(tokens[i].lower) {
                let run = parseRun(tokens, at: i)
                guard run.consumed > 0 else {
                    out.append(tokens[i].text)
                    i += 1
                    continue
                }
                let after = i + run.consumed < tokens.count ? tokens[i + run.consumed].lower : ""
                if decadeWords.contains(after) {
                    out.append(contentsOf: tokens[i..<(i + run.consumed)].map { $0.text })
                } else {
                    out.append(contentsOf: run.pieces)
                }
                i += run.consumed
                continue
            }
            out.append(tokens[i].text)
            i += 1
        }
        return leading + out.joined(separator: " ") + trailing
    }

    // MARK: tokens

    private static func token(_ raw: String) -> Token {
        var chars = Array(raw)
        var lead = "", trail = ""
        while let first = chars.first, "(\"'".contains(first) { lead.append(first); chars.removeFirst() }
        while let last = chars.last, ".,;:!?)\"'".contains(last) { trail = String(last) + trail; chars.removeLast() }
        return Token(lead: lead, core: String(chars), trail: trail)
    }

    private static func isNumberWord(_ word: String) -> Bool { units[word] != nil || tens[word] != nil || scales[word] != nil }

    /// A token made only of two or more number words ("fivezero") becomes those words; anything else is kept.
    private static func split(_ token: Token) -> [Token] {
        let lower = token.lower
        guard lower.count > 4, lower.count <= 64, token.core.first?.isLowercase == true, !isNumberWord(lower), lower.allSatisfy({ $0.isLetter }),
              let parts = segment(lower[...]), parts.count > 1 else { return [token] }
        var result = parts.map { Token(core: $0) }
        result[0].lead = token.lead
        result[result.count - 1].trail = token.trail
        return result
    }

    private static func segment(_ rest: Substring) -> [String]? {
        if rest.isEmpty { return [] }
        for word in vocabulary where rest.hasPrefix(word) {
            if let tail = segment(rest.dropFirst(word.count)) { return [word] + tail }
        }
        return nil
    }

    // MARK: times

    private static func parseTime(_ tokens: [Token], at i: Int, previous: String?) -> (text: String, consumed: Int)? {
        let first = tokens[i]
        guard first.lead.isEmpty, first.trail.isEmpty, let hour = units[first.lower], (1...12).contains(hour) else { return nil }
        var j = i + 1
        var minute: Int?
        if j < tokens.count, tokens[j].lead.isEmpty, tokens[j].trail.isEmpty || meridiemEnd(tokens, at: j) == nil {
            if tokens[j].lower == "oh", j + 1 < tokens.count, let unit = units[tokens[j + 1].lower], (1...9).contains(unit) {
                minute = unit; j += 2
            } else if let tensValue = tens[tokens[j].lower], tensValue <= 50 {
                var value = tensValue
                j += 1
                if j < tokens.count, let unit = units[tokens[j].lower], (1...9).contains(unit), tokens[j - 1].trail.isEmpty {
                    value += unit; j += 1
                }
                minute = value
            } else if let teen = units[tokens[j].lower], (10...19).contains(teen) {
                minute = teen; j += 1
            }
        }
        let afterSentenceBreak = minute != nil && !tokens[j - 1].trail.isEmpty
        let meridiem = afterSentenceBreak ? nil : meridiemEnd(tokens, at: j)
        let leader = previous.map(timeLeaders.contains) == true
        // A bare "am" is also a verb ("which one am I"), so without a minute it needs a word like "at" before the hour.
        let plainAm = meridiem != nil && j < tokens.count && tokens[j].lower == "am"
        guard minute == nil ? (meridiem != nil && (!plainAm || leader)) : (meridiem != nil || leader) else { return nil }
        var text = minute.map { "\(hour):" + String(format: "%02d", $0) } ?? "\(hour)"
        var end = j
        var trail = tokens[j - 1].trail
        if let meridiem {
            text += " " + meridiem.label
            end = meridiem.end
            trail = meridiem.trail
        }
        return (tokens[i].lead + text + trail, end - i)
    }

    /// The am or pm starting at `index`: "am", "pm", "a.m.", "a m" (two tokens).
    private static func meridiemEnd(_ tokens: [Token], at index: Int) -> (label: String, end: Int, trail: String)? {
        guard index < tokens.count else { return nil }
        let word = tokens[index].lower
        switch word {
        case "am", "pm":
            return (word.uppercased(), index + 1, tokens[index].trail)
        case "a.m", "p.m":
            return (word.hasPrefix("a") ? "AM" : "PM", index + 1, String(tokens[index].trail.drop(while: { $0 == "." })))
        case "a", "p":
            guard index + 1 < tokens.count, tokens[index].trail.isEmpty, tokens[index + 1].lower == "m" else { return nil }
            return (word.uppercased() + "M", index + 2, tokens[index + 1].trail)
        default:
            return nil
        }
    }

    // MARK: numbers

    private enum Group {
        case cardinal(Int, words: Int)
        case digits(String)
    }

    private static func parseRun(_ tokens: [Token], at start: Int) -> (pieces: [String], consumed: Int) {
        var groups: [(group: Group, first: Int, last: Int)] = []
        var i = start
        while i < tokens.count, isNumberWord(tokens[i].lower), i == start || tokens[i].lead.isEmpty {
            if let digitEnd = digitRunEnd(tokens, at: i), digitEnd - i >= 3 {
                let digits = tokens[i..<digitEnd].map { String(units[$0.lower]!) }.joined()
                groups.append((.digits(digits), i, digitEnd))
                i = digitEnd
            } else {
                let (value, count) = cardinal(tokens, at: i)
                guard count > 0 else { break }
                groups.append((.cardinal(value, words: count), i, i + count))
                i += count
            }
            if tokens[i - 1].trail != "" { break }
        }
        var pieces = render(groups.map { ($0.group, tokens[$0.first].lead, tokens[$0.last - 1].trail) }, tokens: tokens, groups: groups.map { ($0.first, $0.last) })
        if let last = groups.last, i < tokens.count, tokens[i].lower == "percent", tokens[last.last - 1].trail.isEmpty,
           tokens[i].lead.isEmpty, let text = pieces.last, text.first?.isNumber == true || text.dropFirst().first?.isNumber == true {
            pieces[pieces.count - 1] = text + "%" + tokens[i].trail
            i += 1
        }
        return (pieces, i - start)
    }

    private static func render(
        _ items: [(Group, String, String)], tokens: [Token], groups: [(Int, Int)]
    ) -> [String] {
        // Years: 19 or 20 followed by a two digit number.
        var values = items
        var spans = groups
        var k = 0
        while k + 1 < values.count {
            if case .cardinal(let a, let aWords) = values[k].0, aWords == 1, a == 19 || a == 20,
               case .cardinal(let b, _) = values[k + 1].0, (10...99).contains(b), values[k].2.isEmpty {
                values[k] = (.digits(String(a) + String(b)), values[k].1, values[k + 1].2)
                spans[k] = (spans[k].0, spans[k + 1].1)
                values.remove(at: k + 1)
                spans.remove(at: k + 1)
            }
            k += 1
        }
        // A small lone number next to another number ("three thirty", "seven fifty") is ambiguous: keep the words.
        let hasLoneSmall = values.contains { if case .cardinal(let v, let w) = $0.0 { return v < 10 && w == 1 }; return false }
        if values.count > 1, hasLoneSmall {
            return spans.flatMap { tokens[$0.0..<$0.1].map { $0.text } }
        }
        var pieces: [String] = []
        var index = 0
        while index < values.count {
            let (group, lead, trailInitial) = values[index]
            var trail = trailInitial
            var number: String
            var consumedTail = 0
            switch group {
            case .cardinal(let value, let words):
                if value < 10, words == 1 {
                    pieces.append(contentsOf: tokens[spans[index].0..<spans[index].1].map { $0.text })
                    index += 1
                    continue
                }
                number = String(value)
            case .digits(let digits):
                number = digits
            }
            // 3 digits then 4 digits spoken digit by digit: a phone number.
            if number.count == 3, case .digits(let tail)? = index + 1 < values.count ? values[index + 1].0 : nil, tail.count == 4,
               values[index].2.isEmpty {
                number += "-" + tail
                trail = values[index + 1].2
                consumedTail = 1
            } else if case .digits = group {
                number = phoneShape(number)
            }
            pieces.append(lead + number + trail)
            index += 1 + consumedTail
        }
        return pieces
    }

    private static func phoneShape(_ digits: String) -> String {
        switch digits.count {
        case 7: return digits.prefix(3) + "-" + digits.suffix(4)
        case 10: return digits.prefix(3) + "-" + digits.dropFirst(3).prefix(3) + "-" + digits.suffix(4)
        default: return digits
        }
    }

    /// The end index of a run of single digit words (zero to nine) starting at `i`, or nil if `tokens[i]` is not one
    /// or is followed by a scale word ("five hundred").
    private static func digitRunEnd(_ tokens: [Token], at i: Int) -> Int? {
        var j = i
        while j < tokens.count, let v = units[tokens[j].lower], v <= 9, j == i || tokens[j].lead.isEmpty {
            j += 1
            if tokens[j - 1].trail != "" { break }
        }
        guard j > i else { return nil }
        if j < tokens.count, scales[tokens[j].lower] != nil, tokens[j - 1].trail.isEmpty {
            // "five hundred": the last digit word belongs to the cardinal, not the digit run.
            return j - 1 > i ? j - 1 : nil
        }
        return j
    }

    /// Standard English cardinal grammar: returns the value and how many tokens it used (0 if none).
    private static func cardinal(_ tokens: [Token], at i: Int) -> (value: Int, count: Int) {
        var total = 0, current = 0, lastScale = Int.max
        var j = i
        while j < tokens.count {
            let word = tokens[j].lower
            if j > i, !tokens[j].lead.isEmpty { break }
            if let v = units[word] {
                let low = current % 100
                let afterTens = low >= 20 && low % 10 == 0 && v >= 1 && v <= 9
                guard low == 0 || afterTens, !(v == 0 && j > i) else { break }
                current += v
                if v == 0 { j += 1; break }
            } else if let v = tens[word] {
                guard current % 100 == 0 else { break }
                current += v
            } else if word == "hundred" {
                guard current > 0, current < 100 else { break }
                current *= 100
            } else if let scale = scales[word], scale >= 1000 {
                guard current > 0, scale < lastScale else { break }
                total += current * scale
                current = 0
                lastScale = scale
            } else if word == "and", j > i, j + 1 < tokens.count, tokens[j - 1].trail.isEmpty, tokens[j].trail.isEmpty, tokens[j + 1].lead.isEmpty,
                      units[tokens[j + 1].lower] != nil || tens[tokens[j + 1].lower] != nil,
                      current >= 100 || total > 0, current % 100 == 0 {
                j += 1
                continue
            } else {
                break
            }
            j += 1
            if !tokens[j - 1].trail.isEmpty { break }
        }
        let value = total + current
        return (value, j - i)
    }
}
