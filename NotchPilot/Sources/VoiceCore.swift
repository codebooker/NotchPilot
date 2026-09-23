import Foundation

protocol SpeechFrameClassifier: AnyObject {
    func classify(_ frame:[Float], deliverOn queue:DispatchQueue, completion:@escaping (Result<Float,Error>) -> Void)
    func reset()
}

/// A short slice of an utterance offered for early recognition. `live` candidates are deliberately
/// limited to safe, local actions; ordinary candidates are offered after a short pause.
struct SpeechCandidate {
    let id: Int
    let speechEnd: Int
    let samples: [Float]
    let level: Double?
    let silence: Double
    let live: Bool
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
    /// Silence that ended the last completed phrase, so responses can be timed from the end of speech.
    private(set) var lastSilence: Double = 0
    private var speechEnergy: Double = 0
    private var speechSamples = 0
    private var utteranceID = 0
    private var speechEnd = 0
    private var offeredEnd = -1
    private var offeredLive = false
    private var level: Double? { speechSamples>0 ? 10 * log10(max(speechEnergy / Double(speechSamples), 1e-12)) : nil }

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
            active = true; utterance = lead; lead.removeAll(); voiced = 0; silent = 0; utteranceID += 1
        }
        if active {
            utterance.append(contentsOf: samples)
            if speech {
                voiced += seconds; silent = 0
                speechEnergy += samples.reduce(0.0) { $0 + Double($1 * $1) }; speechSamples += samples.count
                speechEnd = utterance.count
            } else { silent += seconds }
            if Double(utterance.count) / sampleRate > maxDuration {
                overflow = true; reset(); discarding = true; return nil // Discard through the next pause.
            }
            if silent >= pause {
                let result = voiced >= 0.25 ? utterance : nil
                if result != nil { lastLevel = level; lastSilence = silent }
                reset(); return result
            }
        } else {
            lead.append(contentsOf: samples)
            let limit = Int(sampleRate * 0.3)
            if lead.count > limit { lead.removeFirst(lead.count - limit) }
        }
        return nil
    }
    /// Offers a short phrase (at most `maxDuration` of speech) once per pause, after `silence` seconds.
    mutating func candidate(after silence: Double, maxDuration: Double = 3) -> SpeechCandidate? {
        guard active, !discarding, silent >= silence, silent < pause, voiced >= 0.25, offeredEnd != speechEnd,
              Double(speechEnd) / sampleRate <= maxDuration else { return nil }
        offeredEnd = speechEnd
        return SpeechCandidate(id: utteranceID, speechEnd: speechEnd, samples: utterance, level: level, silence: silent, live: false)
    }
    /// Offers one compact in-progress utterance while the speaker is still talking. Recognition may
    /// only claim this when it exactly resolves to a known app-launch command. One attempt avoids
    /// competing Whisper decodes on every VAD frame.
    mutating func liveCandidate(after voicedSeconds: Double = 0.6, maxDuration: Double = 1.6) -> SpeechCandidate? {
        guard active, !discarding, silent == 0, voiced >= voicedSeconds, !offeredLive,
              Double(speechEnd) / sampleRate <= maxDuration else { return nil }
        offeredLive = true
        return SpeechCandidate(id: utteranceID, speechEnd: speechEnd, samples: utterance, level: level, silence: 0, live: true)
    }
    /// Ends the phrase now if nothing was said since the candidate; the rest of the pause emits nothing.
    mutating func claim(_ candidate: SpeechCandidate) -> Bool {
        guard active, utteranceID == candidate.id, speechEnd == candidate.speechEnd else { return false }
        lastLevel = candidate.level; lastSilence = silent
        reset(); return true
    }
    /// Claims a live prefix and keeps any speech received after that prefix as the next phrase.
    /// This is intentionally reserved for exact local app launches. It lets the UI begin "Open
    /// Notes and …" without throwing away the part after "Notes" if Whisper finishes a little late.
    mutating func claimLive(_ candidate: SpeechCandidate) -> Bool {
        guard candidate.live, active, utteranceID == candidate.id, speechEnd >= candidate.speechEnd else { return false }
        lastLevel = candidate.level; lastSilence = silent
        guard speechEnd > candidate.speechEnd else { reset(); return true }
        let tail=Array(utterance[candidate.speechEnd...])
        let tailSpeechEnd=speechEnd-candidate.speechEnd
        reset()
        active=true; utterance=tail; voiced=Double(tailSpeechEnd)/sampleRate
        speechEnergy=tail.reduce(0) { $0 + Double($1 * $1) }; speechSamples=tail.count
        speechEnd=tailSpeechEnd; silent=Double(tail.count-tailSpeechEnd)/sampleRate
        utteranceID += 1
        return true
    }
    mutating func reset() {
        utterance.removeAll(); lead.removeAll(); voiced = 0; silent = 0; active = false
        speechEnergy = 0; speechSamples = 0; speechEnd = 0; offeredEnd = -1; offeredLive = false
        if let nextPause { pause=nextPause; self.nextPause=nil }
    }
}

/// Opt-in "ignore quieter voices": learns the usual level of your phrases and ignores phrases far
/// quieter, such as a television or someone across the room. It does not identify speakers.
struct VoiceLevelGate {
    private(set) var levels: [Double] = []
    let margin = 12.0
    func wouldAccept(_ level: Double) -> Bool {
        guard levels.count >= 3 else { return true }
        let sorted = levels.sorted()
        return level >= sorted[sorted.count / 2] - margin
    }
    mutating func accepts(_ level: Double) -> Bool {
        guard wouldAccept(level) else { return false }
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
