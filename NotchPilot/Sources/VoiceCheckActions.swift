import AppKit
import SwiftUI

extension AppDelegate {
    /// Guided real-voice check. While it runs, what you say is scored against the shown phrase and
    /// never acted on. Phrase levels also train the "ignore quieter voices" baseline.
    func startVoiceCheck() {
        guard !state.busy else { state.detail="Finish or cancel the current task, then start the voice check.";return }
        hidePointing();stopReading()
        state.dictating=false;voiceEditor.target=nil;speech?.setDictation(false)
        state.voiceCheck=VoiceCheck();state.voiceCheckFile=""
        state.phase=state.recording ? "Listening" : state.phase;state.detail="Voice check: read each phrase aloud, then pause."
        presentVoiceCheck()
        // Live QA drives the check with typed phrases; it opens the microphone only with --qa-listen.
        if !state.recording && (qaInbox==nil || CommandLine.arguments.contains("--qa-listen")) { openVoice() }
    }

    func recordVoiceCheck(_ text: String, seconds: Double?, level: Double?) {
        guard var check=state.voiceCheck,!check.finished else { return }
        if VoiceCommandQueue.isStop(text) { stop(close:true);return }
        switch VoiceCheck.control(text) {
        case .skip?: check.skip()
        case .again?: check.again()
        case .stop?: state.voiceCheck=check;endVoiceCheck();return
        case nil: check.record(heard:text,seconds:seconds,level:level)
        }
        state.voiceCheck=check
        if check.finished { endVoiceCheck() }
    }

    func controlVoiceCheck(_ control: VoiceCheck.Control) {
        switch control {
        case .skip: recordVoiceCheck("skip",seconds:nil,level:nil)
        case .again: recordVoiceCheck("try again",seconds:nil,level:nil)
        case .stop: endVoiceCheck()
        }
    }

    /// Stops the check (if still running), keeps the results on screen, and saves them locally.
    func endVoiceCheck() {
        guard var check=state.voiceCheck else { return }
        if !check.finished { check.stop();state.voiceCheck=check }
        let summary=check.summary
        state.detail="Voice check: understood \(summary.understood) of \(summary.attempted) phrases."
        if let file=saveVoiceCheck(check) { state.voiceCheckFile=file.path }
    }

    /// Text results only, no audio, under the runtime's ignored .cache folder.
    func saveVoiceCheck(_ check: VoiceCheck) -> URL? {
        // Rendered previews use sample results; never save those as a real check.
        guard let runtime,!check.results.isEmpty,!CommandLine.arguments.contains(where:{ $0.hasPrefix("--render-") }) else { return nil }
        let folder=URL(fileURLWithPath:runtime.root).appendingPathComponent(".cache/voice-checks",isDirectory:true)
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let formatter=DateFormatter();formatter.dateFormat="yyyyMMdd-HHmmss"
        let file=folder.appendingPathComponent("voice-check-\(formatter.string(from:Date())).json")
        let summary=check.summary
        func value(_ number: Double?) -> Any { number.map { $0 as Any } ?? NSNull() }
        let report:[String:Any]=["date":ISO8601DateFormatter().string(from:Date()),"model":"whisper base.en","pause_seconds":state.speechPause,
            "vocabulary":state.vocabulary,"completed":check.current==nil,
            "summary":["understood":summary.understood,"attempted":summary.attempted,"word_error_rate":summary.wordErrorRate,
                       "median_seconds":value(summary.medianSeconds),"median_level_dbfs":value(summary.medianLevel)],
            "phrases":check.results.map { result -> [String:Any] in
                ["expected":result.phrase.text,"dictation":result.phrase.dictation,"heard":result.heard,"understood":result.understood,
                 "word_error_rate":result.wordErrorRate,"seconds":value(result.seconds),"level_dbfs":value(result.level),"skipped":result.skipped]
            }]
        guard let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),
              (try? data.write(to:file,options:.atomic)) != nil else { return nil }
        return file
    }

    func presentVoiceCheck() {
        if voiceCheckWindow==nil {
            let view=NSHostingView(rootView:VoiceCheckView(state:state))
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:540,height:560),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title="NotchPilot · Voice check";window.contentView=view;window.appearance=state.appearance.native
            window.isReleasedWhenClosed=false;window.delegate=self;window.center()
            voiceCheckWindow=window
        }
        NSApp.activate(ignoringOtherApps:true);voiceCheckWindow?.makeKeyAndOrderFront(nil)
    }
}

struct VoiceCheckView: View {
    @ObservedObject var state: PilotState

    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:12) {
                PilotBuddy(size:36)
                VStack(alignment:.leading,spacing:2) {
                    Text("Voice check").font(.system(size:22,weight:.semibold,design:.rounded))
                    Text("Read each phrase aloud, then pause. Nothing you say is acted on until the check ends.")
                        .font(.system(size:13)).foregroundStyle(PilotStyle.secondary)
                }
            }
            if let check=state.voiceCheck {
                if !check.finished,let phrase=check.current { live(check,phrase) } else { results(check) }
            }
        }.padding(24).frame(width:540,alignment:.topLeading).frame(minHeight:520,alignment:.top).background(PilotStyle.paper)
    }

    @ViewBuilder func live(_ check: VoiceCheck, _ phrase: VoiceCheck.Phrase) -> some View {
        let number=check.results.count+1
        VStack(alignment:.leading,spacing:8) {
            Text("Phrase \(number) of \(check.phrases.count) · \(phrase.dictation ? "Dictation" : "Command")")
                .font(.system(size:12,weight:.medium)).foregroundStyle(PilotStyle.secondary)
            ProgressView(value:Double(number-1),total:Double(check.phrases.count)).tint(PilotStyle.accent)
        }
        Text("“\(phrase.text)”").font(.system(size:30,weight:.semibold,design:.rounded)).foregroundStyle(PilotStyle.ink)
            .frame(maxWidth:.infinity,alignment:.leading).padding(20)
            .background(PilotStyle.card,in:RoundedRectangle(cornerRadius:16))
            .accessibilityLabel("Say: \(phrase.text)")
        Label(state.recording ? "Listening. Read it aloud, then pause." : "Starting the microphone…",systemImage:state.recording ? "mic.fill" : "mic.slash")
            .font(.system(size:14)).foregroundStyle(PilotStyle.ink)
        if let last=check.results.last { outcome(last) }
        Spacer(minLength:0)
        HStack {
            Button("Try again") { state.voiceCheckControl?(.again) }.disabled(check.results.isEmpty)
            Button("Skip") { state.voiceCheckControl?(.skip) }
            Spacer()
            Button("Stop voice check") { state.voiceCheckControl?(.stop) }
        }.controlSize(.large)
        Text("Or say “try again”, “skip”, or “stop voice check”.").font(.system(size:12)).foregroundStyle(PilotStyle.secondary)
    }

    @ViewBuilder func outcome(_ result: VoiceCheck.Result) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:8) {
            Image(systemName:result.skipped ? "forward.fill" : result.understood ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.understood ? PilotStyle.teal : result.skipped ? PilotStyle.secondary : Color.orange)
            VStack(alignment:.leading,spacing:2) {
                Text(result.phrase.text).font(.system(size:13,weight:.medium))
                Text(result.skipped ? "Skipped" : "Heard: “\(result.heard)”"+(result.seconds.map { String(format:" · %.1f s",$0) } ?? ""))
                    .font(.system(size:12)).foregroundStyle(PilotStyle.secondary)
            }
        }.accessibilityElement(children:.combine)
    }

    @ViewBuilder func results(_ check: VoiceCheck) -> some View {
        let summary=check.summary
        VStack(alignment:.leading,spacing:6) {
            Text("Understood \(summary.understood) of \(summary.attempted)").font(.system(size:28,weight:.semibold,design:.rounded))
            Text(details(summary)).font(.system(size:13)).foregroundStyle(PilotStyle.secondary)
        }
        ScrollView {
            VStack(alignment:.leading,spacing:10) { ForEach(Array(check.results.enumerated()),id:\.offset) { outcome($0.element) } }
                .frame(maxWidth:.infinity,alignment:.leading)
        }.frame(maxHeight:250)
        if !state.voiceCheckFile.isEmpty {
            Text("Saved on this Mac (text only, no audio): \((state.voiceCheckFile as NSString).lastPathComponent)")
                .font(.system(size:12)).foregroundStyle(PilotStyle.secondary).textSelection(.enabled)
        }
        HStack {
            Spacer()
            Button("Run again") { state.startVoiceCheck?() }.controlSize(.large)
        }
    }

    func details(_ summary: VoiceCheck.Summary) -> String {
        var parts=[String(format:"%.0f%% of words misheard",summary.wordErrorRate*100)]
        if let seconds=summary.medianSeconds { parts.append(String(format:"responds %.1f s after you stop speaking",seconds)) }
        if let level=summary.medianLevel { parts.append(String(format:"your level %.0f dBFS",level)) }
        return parts.joined(separator:" · ")
    }
}
