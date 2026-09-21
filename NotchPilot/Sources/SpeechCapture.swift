import AVFoundation
import Foundation

// A single engine tap stays open while completed utterances transcribe and execute.
// Buffers are copied before leaving the audio callback; processing lives on one serial queue.
final class SpeechCapture {
    let engine = AVAudioEngine()
    let queue = DispatchQueue(label: "local.notchpilot.audio")
    var segmenter: SpeechSegmenter?
    var pauseDuration: Double = 1.0
    func setPause(_ seconds: Double) {
        queue.sync { pauseDuration=seconds; segmenter?.setPause(seconds) }
    }
    func setDictation(_ enabled:Bool) { queue.sync { segmenter?.maxDuration=enabled ? 120 : 30 } }
    var running = false
    var segmentEpoch = UUID()
    var lastMeter = Date.distantPast
    var onSegment: ((URL, UUID) -> Void)?
    var onLevel: ((CGFloat) -> Void)?
    var onError: ((String) -> Void)?
    var hasPendingSpeech: Bool { queue.sync { segmenter?.active == true || segmenter?.discarding == true } }

    func start() throws {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Microphone unavailable", code: 1)
        }
        queue.sync {
            running = true; segmenter = SpeechSegmenter(sampleRate: format.sampleRate, pause: pauseDuration)
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
            self.queue.async {
                guard self.running else { return }
                if let completed = self.segmenter?.append(samples) {
                    do {
                        let url = try Self.write(completed, sampleRate: format.sampleRate)
                        self.onSegment?(url, self.segmentEpoch)
                    } catch { self.onError?("Could not prepare speech for local Whisper.") }
                }
                if self.segmenter?.overflow == true {
                    self.segmenter?.overflow = false
                    self.onError?("That phrase exceeded the recording limit and was discarded. Pause, then try a shorter phrase.")
                }
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
            segmentEpoch = epoch
            segmenter?.reset()
        }
    }
    func stop() {
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        queue.sync { running = false; segmenter = nil }
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
}
