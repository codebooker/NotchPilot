import Foundation

/// A guided check of real speech: the user reads known phrases, and each transcript is scored
/// instead of acted on. Commands count as understood when they parse to the same command
/// ("Click 7." for "Click seven"); dictation must match word for word.
struct VoiceCheck {
    struct Phrase: Equatable {
        let text: String
        let dictation: Bool
        init(_ text: String, dictation: Bool) { self.text=text; self.dictation=dictation }
    }
    struct Result {
        let phrase: Phrase
        let heard: String
        let understood: Bool
        let wordErrorRate: Double
        let seconds: Double?
        let level: Double?
        let skipped: Bool
    }
    struct Summary: Equatable {
        let understood: Int
        let attempted: Int
        let wordErrorRate: Double
        let medianSeconds: Double?
        let medianLevel: Double?
    }
    enum Control: Equatable { case skip, again, stop }

    static let standard: [Phrase] = [
        Phrase("Open Safari",dictation:false), Phrase("What can I say",dictation:false), Phrase("Show numbers",dictation:false),
        Phrase("Click seven",dictation:false), Phrase("Press command shift S",dictation:false), Phrase("Spell c a t",dictation:false),
        Phrase("Start dictating",dictation:false), Phrase("A little boy rode his purple bike.",dictation:true),
        Phrase("It had flames on it and a bell that rang.",dictation:true), Phrase("Replace purple with blue",dictation:false),
        Phrase("Scratch that",dictation:false), Phrase("Please send the report to Maria before lunch tomorrow.",dictation:true)]

    let phrases: [Phrase]
    private(set) var results: [Result] = []
    private(set) var stopped = false
    init(phrases: [Phrase] = standard) { self.phrases=phrases }

    var current: Phrase? { results.count<phrases.count ? phrases[results.count] : nil }
    var finished: Bool { stopped || current == nil }
    mutating func stop() { stopped=true }
    /// The nearest dictation sentence before the current phrase, as recognition context.
    var previousDictation: String? { phrases.prefix(results.count).last(where:\.dictation)?.text }

    mutating func record(heard: String, seconds: Double?, level: Double?) {
        guard let phrase=current else { return }
        results.append(Result(phrase:phrase,heard:heard,understood:Self.understood(phrase,heard:heard),
                              wordErrorRate:Self.wordErrorRate(phrase.text,heard),seconds:seconds,level:level,skipped:false))
    }
    mutating func skip() {
        guard let phrase=current else { return }
        results.append(Result(phrase:phrase,heard:"",understood:false,wordErrorRate:1,seconds:nil,level:nil,skipped:true))
    }
    /// Re-read the previous phrase (for example after a cough or a stumble).
    mutating func again() { if !results.isEmpty { results.removeLast() } }

    var summary: Summary {
        let attempted=results.filter { !$0.skipped }
        let words=attempted.map { Double(Self.words($0.phrase.text).count) }.reduce(0,+)
        let errors=attempted.map { $0.wordErrorRate*Double(Self.words($0.phrase.text).count) }.reduce(0,+)
        return Summary(understood:attempted.filter(\.understood).count,attempted:attempted.count,
                       wordErrorRate:words>0 ? errors/words : 0,
                       medianSeconds:Self.median(attempted.compactMap(\.seconds)),medianLevel:Self.median(attempted.compactMap(\.level)))
    }

    static func words(_ text: String) -> [String] { VoiceCommandQueue.normalized(text).split(separator:" ").map(String.init) }
    /// Word-level edit distance divided by the expected word count.
    static func wordErrorRate(_ expected: String, _ heard: String) -> Double {
        let a=words(expected),b=words(heard)
        guard !a.isEmpty else { return b.isEmpty ? 0 : 1 }
        var row=Array(0...b.count)
        for i in 1...a.count {
            var previous=row[0];row[0]=i
            for j in stride(from:1,through:b.count,by:1) {
                let saved=row[j]
                row[j]=min(row[j]+1,row[j-1]+1,previous+(a[i-1]==b[j-1] ? 0 : 1))
                previous=saved
            }
        }
        return Double(row[b.count])/Double(a.count)
    }
    static func understood(_ phrase: Phrase, heard: String) -> Bool {
        if phrase.dictation { return wordErrorRate(phrase.text,heard)==0 }
        guard let expected=VoiceEditCommand.parse(phrase.text) else { return false }
        return VoiceEditCommand.parse(heard)==expected
    }
    static func control(_ text: String) -> Control? {
        switch VoiceCommandQueue.normalized(text) {
        case "skip","skip that","skip it","next phrase": return .skip
        case "try again","again","say it again","repeat that": return .again
        case "stop voice check","end voice check","stop the voice check","finish voice check": return .stop
        default: return nil
        }
    }
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted=values.sorted(),middle=sorted.count/2
        return sorted.count%2==0 ? (sorted[middle-1]+sorted[middle])/2 : sorted[middle]
    }
}
