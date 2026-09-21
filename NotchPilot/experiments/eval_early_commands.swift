import AppKit
import AVFoundation

/// Plays synthesized phrases in real time through the production capture, Silero VAD, and Whisper
/// helpers, with early commands off and on. Phrases run as a voice check, so nothing is executed
/// and each response is timed from the end of speech.
///
///   swiftc -swift-version 5 -D SESSION_TESTS -parse-as-library NotchPilot/Sources/*.swift \
///     NotchPilot/experiments/eval_early_commands.swift -o /tmp/eval-early <frameworks>
///   /tmp/eval-early NotchPilot/build/NotchPilot.app/Contents/Resources .cache /tmp/early.json
@main struct EarlyCommandsEval {
    static let phrases: [(String,Bool)] = [("Scratch that",false),("Show numbers",false),("Press command shift S",false),
        ("Delete that",false),("Open Safari",false),("A little boy rode his purple bike.",true)]

    static func clip(_ text: String, in folder: URL) throws -> [Float] {
        let aiff=folder.appendingPathComponent(UUID().uuidString+".aiff"),wav=folder.appendingPathComponent(UUID().uuidString+".wav")
        for arguments in [["/usr/bin/say","-v","Samantha","-o",aiff.path,text],
                          ["/usr/bin/afconvert","-f","WAVE","-d","LEF32@16000","-c","1",aiff.path,wav.path]] {
            let process=Process();process.executableURL=URL(fileURLWithPath:arguments[0]);process.arguments=Array(arguments.dropFirst())
            try process.run();process.waitUntilExit()
        }
        let file=try AVAudioFile(forReading:wav)
        let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!
        try file.read(into:buffer)
        return Array(UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength)))
    }

    static func main() throws {
        _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let arguments=CommandLine.arguments,resources=arguments[1],cache=arguments[2]
        let scratch=FileManager.default.temporaryDirectory.appendingPathComponent("early-eval-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:scratch) }
        // A throwaway root, so the evaluation never writes into real voice-check results.
        let runtime=Runtime(root:scratch.path,python:"",worker:"",whisper:resources+"/whisper-session",
                            model:cache+"/whisper-models/ggml-base.en.bin",vad:resources+"/vad-session",
                            vadModel:cache+"/vad-models/ggml-silero-v6.2.0.bin",planner:"",qwen:"",downloader:"")
        let clips=try phrases.map { try clip($0.0,in:scratch) }
        var report: [[String:Any]] = []
        for early in [false,true] {
            let owner=AppDelegate();owner.runtime=runtime
            owner.panel=FloatingPanel(contentRect:.zero,styleMask:[.borderless],backing:.buffered,defer:false)
            owner.state.earlyCommands=early
            owner.state.voiceCheck=VoiceCheck(phrases:phrases.map { VoiceCheck.Phrase($0.0,dictation:$0.1) })
            let vad=VADSession();try vad.prepare(runtime);try owner.whisperSession.prepare(runtime)
            let capture=SpeechCapture();capture.running=true;capture.segmenter=SpeechSegmenter(sampleRate:16000,pause:1)
            capture.resampler=StreamingResampler(sourceRate:16000);capture.vad=vad
            owner.speech=capture;owner.state.recording=true;owner.wire(capture,token:owner.voiceGeneration)
            RunLoop.current.run(until:Date().addingTimeInterval(1.5)) // Let both helpers load.
            for samples in clips {
                let padded=[Float](repeating:0,count:4800)+samples+[Float](repeating:0,count:32000)
                for start in stride(from:0,to:padded.count,by:1024) {
                    let chunk=Array(padded[start..<min(start+1024,padded.count)])
                    capture.replay(chunk)
                    RunLoop.current.run(until:Date().addingTimeInterval(Double(chunk.count)/16000))
                }
            }
            let deadline=Date().addingTimeInterval(10)
            while (owner.state.voiceCheck?.results.count ?? 0)<phrases.count && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.1)) }
            for result in owner.state.voiceCheck?.results ?? [] {
                report.append(["early_commands":early,"expected":result.phrase.text,"heard":result.heard,"understood":result.understood,
                               "seconds_after_speech":result.seconds.map { $0 as Any } ?? NSNull()])
                print(String(format:"early=%@  %-36@ %5.2f s  %@  heard: %@",early ? "on " : "off",result.phrase.text as NSString,
                             result.seconds ?? -1,result.understood ? "ok " : "MISS",result.heard as NSString))
            }
            vad.shutdown();owner.whisperSession.shutdown()
        }
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:URL(fileURLWithPath:arguments[3]))
    }
}
