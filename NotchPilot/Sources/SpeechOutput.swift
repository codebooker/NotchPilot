import AVFoundation

/// Reads text aloud with the system voice. The host mutes the microphone meanwhile, so nothing
/// spoken here comes back as a request. `done` runs once, when speech finishes or is stopped.
/// Used only from the main thread; delegate callbacks hop back to main.
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var done: (() -> Void)?

    override init() { super.init(); synthesizer.delegate = self }

    func speak(_ text: String, done: @escaping () -> Void) {
        stop(); self.done = done
        synthesizer.speak(AVSpeechUtterance(string: text))
    }
    func stop() {
        let callback = done; done = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        callback?()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { complete() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { complete() }
    private func complete() {
        DispatchQueue.main.async { [weak self] in
            let callback = self?.done; self?.done = nil; callback?()
        }
    }
}
