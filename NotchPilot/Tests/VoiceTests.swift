import Foundation
import AVFoundation

@main struct VoiceTests {
    static func main() throws {
        var vad=SpeechSegmenter(sampleRate:16000)
        let silence=[Float](repeating:0,count:1600)
        let voice=[Float](repeating:0.1,count:1600)
        for _ in 0..<50 { precondition(vad.append(silence)==nil,"Silence must never submit") }
        for _ in 0..<5 { precondition(vad.append(voice)==nil) }
        for _ in 0..<5 { precondition(vad.append(silence)==nil,"Short pauses must not submit") }
        for _ in 0..<5 { precondition(vad.append(voice)==nil) }
        var completed=0
        for _ in 0..<15 { if vad.append(silence) != nil { completed += 1 } }
        precondition(completed==1,"One utterance must submit exactly once")
        for _ in 0..<5 { precondition(vad.append(voice)==nil) }
        for _ in 0..<15 { if vad.append(silence) != nil { completed += 1 } }
        precondition(completed==2,"The microphone stream must accept the next utterance")
        for _ in 0..<305 { precondition(vad.append(voice)==nil,"Do not execute truncated speech") }
        precondition(vad.overflow)
        vad.overflow=false
        for _ in 0..<20 { precondition(vad.append(voice)==nil,"Discard the rest of an overlong sentence") }
        for _ in 0..<15 { precondition(vad.append(silence)==nil,"Never submit the tail of an overlong sentence") }
        for _ in 0..<5 { precondition(vad.append(voice)==nil) }
        var resumed=0
        for _ in 0..<15 { if vad.append(silence) != nil { resumed += 1 } }
        precondition(resumed==1,"Listening must recover after an overlong sentence")
        for _ in 0..<1000 { precondition(vad.append(silence)==nil) }
        for _ in 0..<5 { precondition(vad.append(voice)==nil) }
        for _ in 0..<15 { if vad.append(silence) != nil { resumed += 1 } }
        precondition(resumed==2,"A long quiet pause must not end the session")

        for delay in [1.0,2.0,3.0] {
            var paced=SpeechSegmenter(sampleRate:16000,pause:delay)
            for _ in 0..<5 { precondition(paced.append(voice)==nil) }
            for _ in 0..<Int(delay*10)-1 { precondition(paced.append(silence)==nil,"Respect the selected speaking pause") }
            var count=0
            for _ in 0..<3 { if paced.append(silence) != nil { count += 1 } }
            precondition(count==1,"Each pace emits exactly one instruction")
        }
        var changing=SpeechSegmenter(sampleRate:16000,pause:3)
        for _ in 0..<5 { _=changing.append(voice) }
        changing.setPause(1)
        for _ in 0..<15 { precondition(changing.append(silence)==nil,"Changing pace must not cut off a phrase already in progress") }
        var changedCount=0
        for _ in 0..<17 { if changing.append(silence) != nil { changedCount += 1 } }
        precondition(changedCount==1 && changing.pause==1)
        for _ in 0..<5 { _=changing.append(voice) }
        for _ in 0..<12 { if changing.append(silence) != nil { changedCount += 1 } }
        precondition(changedCount==2,"The next phrase uses the new pause")
        precondition(SpeechSegmenter(sampleRate:16000,pause:0).pause==1)
        precondition(SpeechSegmenter(sampleRate:16000,pause:100).pause==3)
        var queue=VoiceCommandQueue()
        precondition(queue.enqueue("Open Finder")); precondition(queue.next()=="Open Finder")
        precondition(queue.enqueue("Go to Documents")); precondition(queue.enqueue("Open notes.txt"))
        precondition(queue.next()==nil,"No overlapping desktop workers")
        queue.finish(success:true)
        precondition(queue.context==["Open Finder"])
        precondition(queue.next()=="Go to Documents")
        queue.finish(success:false)
        precondition(queue.next()==nil,"Failure must stop dependent follow-ups")
        precondition(queue.enqueue("Save")); queue.cancel()
        precondition(queue.next()==nil && queue.context.isEmpty,"Stop must clear the session")
        for _ in 0..<8 { precondition(queue.enqueue("Next")) }
        precondition(!queue.enqueue("Overflow"))
        precondition(VoiceCommandQueue.isStop("Stop!"))
        precondition(!VoiceCommandQueue.isStop("Open the bus stop file"))
        precondition(VoiceCommandQueue.isCancelTask("Cancel that!"))
        precondition(VoiceCommandQueue.isCancelTask("Never mind."))
        precondition(!VoiceCommandQueue.isCancelTask("Type cancel that into the document"))
        precondition(VoiceCommandQueue.isClearQueue("Clear the queue."))
        precondition(!VoiceCommandQueue.isClearQueue("Search for clear queue examples"))
        print("Voice state tests passed: silence, pauses, continuous utterances, truncation, ordering, failure, cancellation, capacity, stop phrase.")

        // Resampling/writing is the same production path as real microphone buffers.
        let frequencyStep = 2.0 * Double.pi * 440.0 / 48000.0
        let samples: [Float] = (0..<48000).map { Float(sin(Double($0) * frequencyStep) * 0.1) }
        let wav=try SpeechCapture.write(samples,sampleRate:48000)
        defer { try? FileManager.default.removeItem(at:wav) }
        let result=try AVAudioFile(forReading:wav)
        precondition(result.fileFormat.sampleRate==16000 && result.fileFormat.channelCount==1)
        precondition(abs(Int(result.length)-16000)<100)
        print("Microphone audio conversion passed: 48 kHz to mono 16 kHz WAV.")

        // Optional real speech replay: each input is a separate sentence followed by a pause.
        if CommandLine.arguments.count > 2 {
            let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            var emitted=0
            var detector: SpeechSegmenter?
            for path in CommandLine.arguments.dropFirst(2) {
                let file=try AVAudioFile(forReading:URL(fileURLWithPath:path))
                let audio=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!
                try file.read(into:audio)
                let rate=file.processingFormat.sampleRate
                if detector==nil { detector=SpeechSegmenter(sampleRate:rate) }
                precondition(detector!.sampleRate==rate)
                var data=Array(UnsafeBufferPointer(start:audio.floatChannelData![0],count:Int(audio.frameLength)))
                data += [Float](repeating:0,count:Int(rate*1.3))
                for start in stride(from:0,to:data.count,by:1024) {
                    if let segment=detector!.append(Array(data[start..<min(start+1024,data.count)])) {
                        let url=try SpeechCapture.write(segment,sampleRate:rate)
                        try FileManager.default.moveItem(at:url,to:output.appendingPathComponent("utterance-\(emitted).wav"))
                        emitted += 1
                    }
                }
            }
            precondition(emitted==CommandLine.arguments.count-2,"Expected one segment per spoken instruction")
            print("Speech replay emitted \(emitted) instructions without stopping capture.")
        }
    }
}
