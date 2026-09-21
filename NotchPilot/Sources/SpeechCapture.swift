import AVFoundation
import Foundation

// A single engine tap stays open while completed utterances transcribe and execute.
// Buffers are copied before leaving the audio callback; processing lives on one serial queue.
final class SpeechCapture {
    let engine = AVAudioEngine()
    let queue = DispatchQueue(label: "local.notchpilot.audio")
    var segmenter: SpeechSegmenter?
    var resampler: StreamingResampler?
    var pendingFrames: [Float] = []
    weak var vad: SpeechFrameClassifier?
    var vadEpoch = UUID()
    var pauseDuration: Double = 1.0
    func setPause(_ seconds: Double) {
        queue.sync { pauseDuration=seconds; segmenter?.setPause(seconds) }
    }
    func setDictation(_ enabled:Bool) { queue.sync { segmenter?.maxDuration=enabled ? 120 : 30 } }
    var running = false
    var segmentEpoch = UUID()
    var lastMeter = Date.distantPast
    var onSegment: ((URL, UUID, Double?) -> Void)?
    var onLevel: ((CGFloat) -> Void)?
    var onVoiceActivity: (() -> Void)?
    var onError: ((String) -> Void)?
    /// While NotchPilot speaks, microphone audio is dropped rather than segmented.
    private(set) var muted = false
    func setMuted(_ on: Bool) {
        queue.sync {
            muted=on;vadEpoch=UUID()
            segmenter?.reset();pendingFrames.removeAll();resampler?.reset();vad?.reset()
        }
    }
    var hasPendingSpeech: Bool { queue.sync { segmenter?.active == true || segmenter?.discarding == true } }

    func start(vad: SpeechFrameClassifier) throws {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Microphone unavailable", code: 1)
        }
        queue.sync {
            running = true; self.vad=vad; segmenter = SpeechSegmenter(sampleRate: 16000, pause: pauseDuration)
            resampler=StreamingResampler(sourceRate:format.sampleRate); pendingFrames=[];vadEpoch=UUID()
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
            self.queue.async {
                guard self.running,!self.muted else { return }
                self.enqueueForVAD(samples)
                if Date().timeIntervalSince(self.lastMeter) > 0.08 {
                    self.lastMeter = Date()
                    let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1,samples.count)))
                    self.onLevel?(CGFloat(min(1, max(0.03, rms * 12))))
                }
            }
        }
        do { engine.prepare(); try engine.start() }
        catch { stop(); throw error }
    }
    func discardPendingSpeech(epoch: UUID) {
        queue.sync {
            segmentEpoch = epoch;vadEpoch=UUID()
            segmenter?.reset();pendingFrames.removeAll();resampler?.reset();vad?.reset()
        }
    }
    func stop() {
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        queue.sync { running = false;vadEpoch=UUID(); segmenter = nil;pendingFrames.removeAll();resampler=nil;vad?.reset();vad=nil }
    }
    static func write(_ samples: [Float], sampleRate: Double) throws -> URL {
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        source.frameLength = source.frameCapacity
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from:$0.baseAddress!, count:$0.count) }
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)!
        let target = AVAudioPCMBuffer(pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * 16000 / sampleRate) + 1024))!
        var supplied = false; var error: NSError?
        let status = converter.convert(to: target, error: &error) { _, flag in
            if supplied { flag.pointee = .endOfStream; return nil }
            supplied = true; flag.pointee = .haveData; return source
        }
        if let error { throw error }
        guard status != .error, target.frameLength > 0 else { throw NSError(domain:"Audio conversion",code:1) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notchpilot-\(UUID()).wav")
        do {
            let file = try AVAudioFile(forWriting:url, settings:[AVFormatIDKey:kAudioFormatLinearPCM,
                AVSampleRateKey:16000, AVNumberOfChannelsKey:1, AVLinearPCMBitDepthKey:16,
                AVLinearPCMIsFloatKey:false, AVLinearPCMIsBigEndianKey:false],
                commonFormat:.pcmFormatFloat32, interleaved:false)
            try file.write(from:target)
        } catch { try? FileManager.default.removeItem(at:url); throw error }
        return url
    }

    private func enqueueForVAD(_ samples:[Float]) {
        guard let resampled=resampler?.append(samples),!resampled.isEmpty,let vad else { return }
        pendingFrames.append(contentsOf:resampled)
        while pendingFrames.count >= 512 {
            let frame=Array(pendingFrames.prefix(512));pendingFrames.removeFirst(512)
            let epoch=vadEpoch
            vad.classify(frame,deliverOn:queue) { [weak self] result in
                guard let self,self.running,self.vadEpoch==epoch else { return }
                switch result {
                case .failure(let error): self.onError?(error.localizedDescription)
                case .success(let probability): self.consume(frame,speech:probability >= 0.5)
                }
            }
        }
    }

    private func consume(_ samples:[Float],speech:Bool) {
        if speech { onVoiceActivity?() }
        if let completed=segmenter?.append(samples,speech:speech) {
            do { onSegment?(try Self.write(completed,sampleRate:16000),segmentEpoch,segmenter?.lastLevel) }
            catch { onError?("Could not prepare speech for local Whisper.") }
            vad?.reset()
        }
        if segmenter?.overflow == true {
            segmenter?.overflow=false;vad?.reset()
            onError?("That phrase exceeded the recording limit and was discarded. Pause, then try a shorter phrase.")
        }
    }
}

/// Maintains fractional timing across arbitrary microphone callback sizes.
struct StreamingResampler {
    let sourceRate: Double
    private let targetRate: Double = 16000
    private var carry:[Float] = []
    private var position:Double = 0
    init(sourceRate:Double) { self.sourceRate=sourceRate }
    mutating func append(_ samples:[Float]) -> [Float] {
        carry.append(contentsOf:samples)
        guard carry.count>1 else { return [] }
        let step=sourceRate/targetRate;var output:[Float]=[]
        while position+1<Double(carry.count) {
            let i=Int(position);let fraction=Float(position-Double(i))
            output.append(carry[i]*(1-fraction)+carry[i+1]*fraction)
            position += step
        }
        let drop=max(0,Int(position)-1)
        if drop>0 { carry.removeFirst(drop);position -= Double(drop) }
        return output
    }
    mutating func reset() { carry.removeAll();position=0 }
}
