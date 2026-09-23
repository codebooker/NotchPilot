import Foundation
import AVFoundation

@main struct VoiceTests {
    static func main() throws {
        var vad=SpeechSegmenter(sampleRate:16000)
        let silence=[Float](repeating:0,count:1600)
        let voice=[Float](repeating:0.1,count:1600)
        for _ in 0..<50 { precondition(vad.append(silence,speech:false)==nil,"Silence must never submit") }
        for _ in 0..<5 { precondition(vad.append(voice,speech:true)==nil) }
        for _ in 0..<5 { precondition(vad.append(silence,speech:false)==nil,"Short pauses must not submit") }
        for _ in 0..<5 { precondition(vad.append(voice,speech:true)==nil) }
        var completed=0
        for _ in 0..<15 { if vad.append(silence,speech:false) != nil { completed += 1 } }
        precondition(completed==1,"One utterance must submit exactly once")
        for _ in 0..<5 { precondition(vad.append(voice,speech:true)==nil) }
        for _ in 0..<15 { if vad.append(silence,speech:false) != nil { completed += 1 } }
        precondition(completed==2,"The microphone stream must accept the next utterance")
        for _ in 0..<305 { precondition(vad.append(voice,speech:true)==nil,"Do not execute truncated speech") }
        precondition(vad.overflow)
        vad.overflow=false
        for _ in 0..<20 { precondition(vad.append(voice,speech:true)==nil,"Discard the rest of an overlong sentence") }
        for _ in 0..<15 { precondition(vad.append(silence,speech:false)==nil,"Never submit the tail of an overlong sentence") }
        for _ in 0..<5 { precondition(vad.append(voice,speech:true)==nil) }
        var resumed=0
        for _ in 0..<15 { if vad.append(silence,speech:false) != nil { resumed += 1 } }
        precondition(resumed==1,"Listening must recover after an overlong sentence")
        for _ in 0..<1000 { precondition(vad.append(silence,speech:false)==nil) }
        for _ in 0..<5 { precondition(vad.append(voice,speech:true)==nil) }
        for _ in 0..<15 { if vad.append(silence,speech:false) != nil { resumed += 1 } }
        precondition(resumed==2,"A long quiet pause must not end the session")

        for delay in [1.0,2.0,3.0] {
            var paced=SpeechSegmenter(sampleRate:16000,pause:delay)
            for _ in 0..<5 { precondition(paced.append(voice,speech:true)==nil) }
            for _ in 0..<Int(delay*10)-1 { precondition(paced.append(silence,speech:false)==nil,"Respect the selected speaking pause") }
            var count=0
            for _ in 0..<3 { if paced.append(silence,speech:false) != nil { count += 1 } }
            precondition(count==1,"Each pace emits exactly one instruction")
        }
        var changing=SpeechSegmenter(sampleRate:16000,pause:3)
        for _ in 0..<5 { _=changing.append(voice,speech:true) }
        changing.setPause(1)
        for _ in 0..<15 { precondition(changing.append(silence,speech:false)==nil,"Changing pace must not cut off a phrase already in progress") }
        var changedCount=0
        for _ in 0..<17 { if changing.append(silence,speech:false) != nil { changedCount += 1 } }
        precondition(changedCount==1 && changing.pause==1)
        for _ in 0..<5 { _=changing.append(voice,speech:true) }
        for _ in 0..<12 { if changing.append(silence,speech:false) != nil { changedCount += 1 } }
        precondition(changedCount==2,"The next phrase uses the new pause")
        precondition(SpeechSegmenter(sampleRate:16000,pause:0).pause==1)
        precondition(SpeechSegmenter(sampleRate:16000,pause:100).pause==3)
        var longDictation=SpeechSegmenter(sampleRate:16000)
        longDictation.maxDuration=120
        for _ in 0..<350 { precondition(longDictation.append(voice,speech:true)==nil) }
        var longCount=0
        for _ in 0..<15 { if longDictation.append(silence,speech:false) != nil { longCount += 1 } }
        precondition(longCount==1 && !longDictation.overflow,"Dictation accepts a phrase longer than the command limit")
        var queue=VoiceCommandQueue()
        precondition(queue.enqueue("Open Finder")); precondition(queue.next()=="Open Finder")
        precondition(queue.enqueue("Go to Documents")); precondition(queue.enqueue("Open notes.txt"))
        precondition(queue.next()==nil,"No overlapping desktop workers")
        queue.finish(success:true)
        precondition(queue.context==["Open Finder"])
        precondition(queue.next()=="Go to Documents")
        queue.finish(success:false)
        precondition(queue.next()==nil,"Failure must stop dependent follow-ups")
        // A phrase's level comes from its speech frames only, so the closing pause does not dilute it.
        var measured=SpeechSegmenter(sampleRate:16000)
        for _ in 0..<5 { _=measured.append(voice,speech:true) }
        for _ in 0..<15 { _=measured.append(silence,speech:false) }
        precondition(abs((measured.lastLevel ?? 0) - (-20)) < 0.1,"0.1 RMS speech is -20 dBFS")
        var gate=VoiceLevelGate()
        precondition(gate.accepts(-40),"Nothing is ignored before your level is known")
        for level in [-20.0,-22,-18] { precondition(gate.accepts(level)) }
        precondition(!gate.accepts(-38),"A voice far quieter than yours is ignored")
        precondition(gate.accepts(-28),"Speaking a little more softly is still you")
        precondition(!gate.wouldAccept(-38) && gate.wouldAccept(-25) && gate.levels.count==5,"Checking a level does not learn it")
        var restored=VoiceLevelGate(levels:gate.levels)
        precondition(!restored.accepts(-38),"A saved baseline works right after launch")
        // Early commands: a short phrase can be guessed partway through the pause and claimed if it is a
        // complete command, so the rest of the pause emits nothing. New speech invalidates a guess.
        var early=SpeechSegmenter(sampleRate:16000,pause:1)
        for _ in 0..<5 { _=early.append(voice,speech:true) }
        for _ in 0..<3 { _=early.append(silence,speech:false) }
        precondition(early.candidate(after:0.4)==nil,"Too early to guess")
        _=early.append(silence,speech:false)
        let guess=early.candidate(after:0.4)!
        precondition(abs(guess.silence-0.4)<0.01 && guess.level != nil && !guess.samples.isEmpty)
        precondition(early.candidate(after:0.4)==nil,"One guess per pause")
        precondition(early.claim(guess) && !early.active,"A confirmed command ends the phrase now")
        for _ in 0..<10 { precondition(early.append(silence,speech:false)==nil,"The rest of the pause emits nothing") }
        for _ in 0..<5 { _=early.append(voice,speech:true) }
        for _ in 0..<4 { _=early.append(silence,speech:false) }
        let stale=early.candidate(after:0.4)!
        _=early.append(voice,speech:true)
        precondition(!early.claim(stale),"Speaking again keeps listening")
        var emitted=0
        for _ in 0..<12 { if early.append(silence,speech:false) != nil { emitted+=1 } }
        precondition(emitted==1 && abs(early.lastSilence-1.0)<0.11,"Unclaimed phrases still end after the full pause, reporting it")
        // A single in-progress snapshot can make a finite app launch feel immediate. It must never
        // steal the rest of an utterance: more speech invalidates the snapshot and normal capture continues.
        var live=SpeechSegmenter(sampleRate:16000,pause:1)
        for _ in 0..<5 { _=live.append(voice,speech:true) }
        precondition(live.liveCandidate()==nil,"Wait for enough spoken audio before one live decode")
        _=live.append(voice,speech:true)
        let liveGuess=live.liveCandidate()!
        precondition(liveGuess.live && liveGuess.silence==0 && !liveGuess.samples.isEmpty,"The candidate is marked as live")
        precondition(live.liveCandidate()==nil,"Only one live decode per utterance")
        _=live.append(voice,speech:true)
        precondition(live.claimLive(liveGuess) && live.active,"A live app launch keeps the words spoken after its prefix")
        for _ in 0..<2 { _=live.append(voice,speech:true) }
        var liveCompleted=0
        for _ in 0..<12 { if live.append(silence,speech:false) != nil { liveCompleted+=1 } }
        precondition(liveCompleted==1,"The preserved tail still submits after the selected pause")
        var lengthy=SpeechSegmenter(sampleRate:16000,pause:1)
        for _ in 0..<40 { _=lengthy.append(voice,speech:true) }
        for _ in 0..<5 { _=lengthy.append(silence,speech:false) }
        precondition(lengthy.candidate(after:0.4)==nil,"Long phrases are never guessed")
        var dictation=VoiceCommandQueue()
        precondition(dictation.enqueue("Replace missing with text")); precondition(dictation.enqueue("Next sentence."))
        _=dictation.next(); dictation.skipActive()
        precondition(dictation.next()=="Next sentence." && dictation.context.isEmpty,"A failed dictation phrase must not drop later speech")
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

        var resampler=StreamingResampler(sourceRate:48000)
        let split=[Float](repeating:0.1,count:24000)
        let first=resampler.append(split),second=resampler.append(split)
        precondition(abs(first.count+second.count-16000)<2,"Streaming resampling keeps 16 kHz timing across callbacks")

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
                    let frame=Array(data[start..<min(start+1024,data.count)])
                    // Replay is a segmentation fixture. Production VAD decisions are
                    // separately tested through the bundled Silero helper.
                    let speech=frame.contains { abs($0)>0.003 }
                    if let segment=detector!.append(frame,speech:speech) {
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
