import Foundation

protocol SpeechFrameClassifier: AnyObject {
    func classify(_ frame:[Float], deliverOn queue:DispatchQueue, completion:@escaping (Result<Float,Error>) -> Void)
    func reset()
}

// Pure state machines shared by microphone capture, the app, and replay tests.
struct SpeechSegmenter {
    let sampleRate: Double
    var pause: Double = 1.0
    private var nextPause: Double?

    init(sampleRate: Double, pause: Double = 1.0) {
        self.sampleRate=sampleRate; self.pause=min(3,max(1,pause))
    }
    mutating func setPause(_ seconds: Double) {
        let value=min(3,max(1,seconds))
        if active || discarding { nextPause=value } else { pause=value }
    }
    var lead: [Float] = []
    var utterance: [Float] = []
    var voiced: Double = 0
    var silent: Double = 0
    var maxDuration: Double = 30
    var active = false
    var overflow = false
    var discarding = false
    /// Level of the last completed phrase in dBFS, measured over its speech frames only.
    private(set) var lastLevel: Double?
    private var speechEnergy: Double = 0
    private var speechSamples = 0

    /// `speech` comes from the resident Silero VAD, not a volume threshold.
    mutating func append(_ samples: [Float], speech: Bool) -> [Float]? {
        guard !samples.isEmpty else { return nil }
        let seconds = Double(samples.count) / sampleRate
        if discarding {
            silent = speech ? 0 : silent + seconds
            if silent >= pause { discarding = false; reset() }
            return nil
        }
        if speech && !active {
            active = true; utterance = lead; lead.removeAll(); voiced = 0; silent = 0
        }
        if active {
            utterance.append(contentsOf: samples)
            if speech {
                voiced += seconds; silent = 0
                speechEnergy += samples.reduce(0.0) { $0 + Double($1 * $1) }; speechSamples += samples.count
            } else { silent += seconds }
            if Double(utterance.count) / sampleRate > maxDuration {
                overflow = true; reset(); discarding = true; return nil // Discard through the next pause.
            }
            if silent >= pause {
                let result = voiced >= 0.25 ? utterance : nil
                if result != nil { lastLevel = 10 * log10(max(speechEnergy / Double(max(1, speechSamples)), 1e-12)) }
                reset(); return result
            }
        } else {
            lead.append(contentsOf: samples)
            let limit = Int(sampleRate * 0.3)
            if lead.count > limit { lead.removeFirst(lead.count - limit) }
        }
        return nil
    }
    mutating func reset() {
        utterance.removeAll(); lead.removeAll(); voiced = 0; silent = 0; active = false
        speechEnergy = 0; speechSamples = 0
        if let nextPause { pause=nextPause; self.nextPause=nil }
    }
}

/// Opt-in "ignore quieter voices": learns the usual level of your phrases and ignores phrases far
/// quieter, such as a television or someone across the room. It does not identify speakers.
struct VoiceLevelGate {
    private(set) var levels: [Double] = []
    let margin = 12.0
    mutating func accepts(_ level: Double) -> Bool {
        if levels.count >= 3 {
            let sorted = levels.sorted()
            if level < sorted[sorted.count / 2] - margin { return false }
        }
        levels.append(level); levels = Array(levels.suffix(20)); return true
    }
}

struct VoiceCommandQueue {
    private(set) var pending: [String] = []
    private(set) var active: String?
    private(set) var context: [String] = []
    mutating func enqueue(_ text: String) -> Bool {
        guard pending.count < 8 else { return false }
        pending.append(text); return true
    }
    mutating func next() -> String? {
        guard active == nil, !pending.isEmpty else { return nil }
        active = pending.removeFirst(); return active
    }
    mutating func finish(success: Bool, resolved: String? = nil) {
        if success, let active {
            context.append(resolved ?? active); context = Array(context.suffix(6))
        } else { pending.removeAll() }
        active = nil
    }
    /// Dictation phrases are independent: one failed correction must not drop the sentences after it.
    mutating func skipActive() { active = nil }
    mutating func cancel() { pending.removeAll(); active = nil; context.removeAll() }
    mutating func discardPending() { pending.removeAll() }
    static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func isStop(_ text: String) -> Bool {
        ["stop", "cancel", "stop listening", "stop everything", "stop notchpilot"].contains(normalized(text))
    }
    static func isCancelTask(_ text: String) -> Bool {
        ["cancel that", "cancel this task", "cancel the task", "never mind", "nevermind"].contains(normalized(text))
    }
    static func isResumeTask(_ text: String) -> Bool {
        ["resume task", "resume the task", "continue working"].contains(normalized(text))
    }
    static func isClearQueue(_ text: String) -> Bool {
        ["clear the queue", "clear queue", "clear waiting requests"].contains(normalized(text))
    }
}
