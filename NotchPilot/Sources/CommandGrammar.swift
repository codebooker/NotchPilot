import CoreGraphics
import Foundation

enum TextUnit: String, Equatable { case word, sentence, paragraph }
enum TextDirection: Equatable { case previous, next }
enum TextCase: Equatable { case capitalized, uppercase, lowercase }
enum ReadScope: Equatable { case that, document }

/// "What can I say?" Built from example phrases that the session tests parse, so help cannot
/// advertise a command that does not work.
enum VoiceHelp {
    static let sections: [(String, [String])] = [
        ("Dictate", ["Start dictating","Done dictating","New paragraph","Scratch that","Spell c a t","Literal text new line"]),
        ("Edit", ["Select purple bike","Select previous word","Delete that","Replace purple with blue","Capitalize that","Insert after little","Select all"]),
        ("Point", ["Show numbers","Click 5","Click Save","Mouse grid","Double click","Right click"]),
        ("Keys and apps", ["Press command S","Next field","Open Safari","Save as Note on my desktop","Add that to vocabulary"]),
        ("Listen", ["Read that","Go to sleep","Wake up","Cancel that","Stop"])]
    static var text: String { sections.map { $0.0+": "+$0.1.joined(separator:" · ") }.joined(separator:"\n") }
}

/// A key plus modifiers, spoken as "press command shift s".
struct KeyChord: Equatable {
    let code: CGKeyCode
    var command = false, shift = false, option = false, control = false
    init(code: CGKeyCode, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.code=code; self.command=command; self.shift=shift; self.option=option; self.control=control
    }
    var flags: CGEventFlags {
        var flags: CGEventFlags = []
        if command { flags.insert(.maskCommand) }; if shift { flags.insert(.maskShift) }
        if option { flags.insert(.maskAlternate) }; if control { flags.insert(.maskControl) }
        return flags
    }
    var label: String {
        let modifiers=(control ? "⌃" : "")+(option ? "⌥" : "")+(shift ? "⇧" : "")+(command ? "⌘" : "")
        let names=Self.names.filter { $0.value==code }.map(\.key)
        let name=names.min { ($0.count,$0)<($1.count,$1) } ?? "key"
        return modifiers+(name.count==1 ? name.uppercased() : name.capitalized)
    }
    static let names: [String:CGKeyCode] = {
        var keys: [String:CGKeyCode] = ["return":36,"enter":36,"escape":53,"tab":48,"space":49,"spacebar":49,"delete":51,"backspace":51,
            "forward delete":117,"up":126,"down":125,"left":123,"right":124,"home":115,"end":119,"page up":116,"page down":121,
            "comma":43,"period":47,"slash":44,"minus":27,"equals":24,"semicolon":41,"quote":39,"backslash":42,
            "left bracket":33,"right bracket":30,"grave":50,"backtick":50]
        let letters: [CGKeyCode] = [0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6]
        for (index, code) in letters.enumerated() { keys[String(UnicodeScalar(UInt8(97+index)))]=code }
        let digits: [CGKeyCode] = [29,18,19,20,21,23,22,26,28,25]
        for (index, code) in digits.enumerated() { keys[String(index)]=code; keys[Spelling.numberWords[index]]=code }
        let functions: [CGKeyCode] = [122,120,99,118,96,97,98,100,101,109,103,111]
        for (index, code) in functions.enumerated() { keys["f\(index+1)"]=code }
        return keys
    }()
    /// Words after "press"/"hit": any modifiers, then exactly one key. Nil for anything else.
    static func parse(_ words: [String]) -> KeyChord? {
        var chord = KeyChord(code:0); var rest = words[...]
        while let word = rest.first {
            switch word {
            case "command","cmd": chord.command = true
            case "shift": chord.shift = true
            case "option","alt": chord.option = true
            case "control","ctrl": chord.control = true
            default:
                let key = rest.joined(separator:" ")
                if let code = names[key] ?? names[key.replacingOccurrences(of:" arrow",with:"")]
                    ?? Spelling.symbol(for:key).flatMap({ $0.count==1 ? names[$0] : nil }) {
                    chord = KeyChord(code:code,command:chord.command,shift:chord.shift,option:chord.option,control:chord.control)
                    return chord
                }
                return nil
            }
            rest = rest.dropFirst()
        }
        return nil
    }
}

/// Letters, the NATO alphabet, and symbols for "spell …". Whisper writes spoken letters as words
/// ("see a tea"), so both forms map.
enum Spelling {
    static let numberWords = ["zero","one","two","three","four","five","six","seven","eight","nine"]
    static let letterWords: [String:String] = [
        "bee":"b","be":"b","see":"c","sea":"c","dee":"d","ee":"e","ef":"f","eff":"f","gee":"g","aitch":"h","eye":"i","jay":"j",
        "kay":"k","el":"l","ell":"l","em":"m","en":"n","oh":"o","pee":"p","pea":"p","cue":"q","queue":"q","are":"r","ar":"r",
        "es":"s","ess":"s","tee":"t","tea":"t","you":"u","vee":"v","ex":"x","why":"y","zee":"z","zed":"z",
        "alpha":"a","alfa":"a","bravo":"b","charlie":"c","delta":"d","echo":"e","foxtrot":"f","golf":"g","hotel":"h","india":"i",
        "juliet":"j","juliett":"j","kilo":"k","lima":"l","mike":"m","november":"n","oscar":"o","papa":"p","quebec":"q","romeo":"r",
        "sierra":"s","tango":"t","uniform":"u","victor":"v","whiskey":"w","xray":"x","yankee":"y","zulu":"z"]
    static let symbols: [String:String] = ["space":" ","dash":"-","hyphen":"-","dot":".","period":".","point":".","underscore":"_",
        "at":"@","slash":"/","apostrophe":"'","plus":"+","comma":","]
    static func symbol(for word: String) -> String? {
        if word.count==1, word.first!.isLetter || word.first!.isNumber { return word }
        if let index=numberWords.firstIndex(of:word) { return String(index) }
        return letterWords[word]
    }
    /// "c a t" → "cat"; "cap j o h n" → "John"; "all caps n a s a" → "NASA"; "j at example dot com".
    /// Whole words are allowed only alongside a symbol word (addresses); otherwise nil.
    static func parse(_ words: [String]) -> String? {
        var result = ""; var capitalNext = false; var allCaps = false; var literal = false; var sawSymbol = false
        var index = 0
        while index < words.count {
            let word = words[index]
            if word=="all", index+1<words.count, words[index+1]=="caps" { allCaps=true; index += 2; continue }
            if ["cap","capital","uppercase"].contains(word) { capitalNext=true; index += 1; continue }
            if word=="double", index+1<words.count, ["u","you"].contains(words[index+1]) { result += capitalNext || allCaps ? "W" : "w"; capitalNext=false; index += 2; continue }
            if let symbol=symbols[word] { result += symbol; sawSymbol=true }
            else if let letter=symbol(for:word) { result += capitalNext || allCaps ? letter.uppercased() : letter }
            else if word.allSatisfy({ $0.isLetter || $0.isNumber }) { result += allCaps ? word.uppercased() : word; literal=true }
            else { return nil }
            capitalNext=false; index += 1
        }
        return result.isEmpty || (literal && !sawSymbol) ? nil : result
    }
}

/// Pure text ranges for relative selection and deletion.
enum TextCommands {
    static func units(_ unit: TextUnit, in text: String) -> [NSRange] {
        let source = text as NSString; var ranges: [NSRange] = []
        let option: NSString.EnumerationOptions = unit == .word ? .byWords : unit == .sentence ? .bySentences : .byParagraphs
        source.enumerateSubstrings(in:NSRange(location:0,length:source.length),options:[option,.substringNotRequired]) { _, range, _, _ in
            var end = NSMaxRange(range)
            if unit == .word { // Keep punctuation attached to the word ("bike.").
                while end < source.length, let scalar = UnicodeScalar(source.character(at:end)),
                      CharacterSet.punctuationCharacters.contains(scalar) { end += 1 }
            }
            while end > range.location, let scalar = UnicodeScalar(source.character(at:end-1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
            if end > range.location { ranges.append(NSRange(location:range.location,length:end-range.location)) }
        }
        return ranges
    }
    /// Previous: the last `count` units starting before the caret. Next: the first `count` units
    /// ending after the selection. Nil when there are none.
    static func range(_ unit: TextUnit, _ direction: TextDirection, _ count: Int, in text: String, selection: NSRange) -> NSRange? {
        let all = units(unit, in:text)
        if direction == .previous {
            let before = all.filter { $0.location < selection.location }.suffix(count)
            guard let first = before.first, let last = before.last else { return nil }
            let end = min(selection.location, NSMaxRange(last))
            return NSRange(location:first.location,length:end-first.location)
        }
        let after = all.filter { NSMaxRange($0) > NSMaxRange(selection) }.prefix(count)
        guard let first = after.first, let last = after.last else { return nil }
        let start = max(first.location, NSMaxRange(selection))
        return NSRange(location:start,length:NSMaxRange(last)-start)
    }
    /// Also removes one preceding space when the deletion would otherwise leave a double space or a
    /// space before punctuation or the end of the text.
    static func forDeletion(_ range: NSRange, in text: String) -> NSRange {
        let source = text as NSString
        guard range.location > 0, source.character(at:range.location-1) == 32 else { return range }
        let end = NSMaxRange(range)
        if end == source.length { return NSRange(location:range.location-1,length:range.length+1) }
        guard let next = UnicodeScalar(source.character(at:end)),
              CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains(next) else { return range }
        return NSRange(location:range.location-1,length:range.length+1)
    }
    static func transform(_ text: String, _ style: TextCase) -> String {
        switch style {
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .capitalized:
            var result = ""; var startOfWord = true
            for character in text {
                if character.isLetter { result += startOfWord ? character.uppercased() : String(character); startOfWord = false }
                else { result.append(character); startOfWord = !(character == "'" || character == "’" || character.isNumber) }
            }
            return result
        }
    }
}
