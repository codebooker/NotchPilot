import AppKit

extension AppDelegate {
    @discardableResult func handleLocalVoiceCommand(_ goal:String) -> Bool {
        var command=VoiceEditCommand.parse(goal)
        // A bare number or "go back" means something only while numbers or the grid are showing.
        switch (command,pointing) {
        case (.number?,nil),(.gridBack?,nil),(.gridBack?,.numbers?): command=nil
        default: break
        }
        if command?.isPointing != true { hidePointing() }
        guard command != nil || state.dictating else { return false }
        rememberTarget()
        let token=UUID();generation=token;state.busy=true;state.cost=0
        if case .openApp(let bundle)=command, !appLaunchDeduper.accepts(bundle) {
            finishVoiceAction("Already opening that app. Ready for your next request.",token:token);return true
        }
        if state.preview { finishVoiceAction("Preview: voice editing would run locally. No document changed.",token:token);return true }
        Task { @MainActor in
        var command=command
        do {
            activityWindow?.orderOut(nil);targetApp?.activate(options:[])
            try await Task.sleep(nanoseconds:150_000_000)
            guard generation==token else { return }
            if command == .help {
                finishVoiceAction("Here is what you can say. Anything else is a request for the current app.",token:token)
                state.showHelp=true;presentActivity();return
            }
            if command == .end {
                state.dictating=false;speech?.setDictation(false);voiceEditor.target=nil
                finishVoiceAction("Command mode. Tell me what to do next.",token:token);return
            }
            if case .openApp(let bundle)=command {
                guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) else { throw VoiceEditor.problem("That app is not installed.") }
                let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
                let opened=try await NSWorkspace.shared.openApplication(at:url,configuration:configuration)
                guard generation==token else { return }
                opened.activate(options:[])
                try await Task.sleep(nanoseconds:200_000_000)
                guard generation==token else { return }
                targetApp=opened;targetWindowID=HostKeyboard.frontWindow(pid:opened.processIdentifier,bundle:bundle)
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier==opened.processIdentifier,targetWindowID != nil else {
                    throw VoiceEditor.problem("The app opened, but its window is not ready. Try the request again.")
                }
                state.dictating=false;speech?.setDictation(false);voiceEditor.target=nil
                finishVoiceAction("Opened "+(opened.localizedName ?? "the app")+". Ready for your next request.",token:token);return
            }
            var keptAsText=false
            if let pointingCommand=command,pointingCommand.isPointing {
                if try await handlePointing(pointingCommand,token:token) { return }
                command=nil;keptAsText=true // A dictated "click here…" that matched no control.
            }
            if case .addWord(let word?)=command { finishVocabulary(word,add:true,token:token);return }
            if case .removeWord(let word)=command { finishVocabulary(word,add:false,token:token);return }
            let currentTarget=targetApp.flatMap { app in targetWindowID.map { (pid:app.processIdentifier,window:$0) } }
            if state.dictating,let parsed=command,let bound=voiceEditor.target,
               parsed.isProse(in:voiceEditor.documentText(pid:bound.pid,window:bound.window)) { command=nil;keptAsText=true }
            let destination: (pid:pid_t,window:Int)?
            if case .saveAs=command { destination=currentTarget } else { destination=voiceEditor.target ?? currentTarget }
            guard let destination else { throw VoiceEditor.problem("Open a document first, then say start dictating.") }
            let pid=destination.pid;let window=destination.window
            // Restore the bound document after the user submits from our conversation UI.
            activityWindow?.orderOut(nil);targetApp?.activate(options:[]);showPanel(key:false)
            if case .key(let name)=command {
                let codes:[String:CGKeyCode] = ["tab":48,"backtab":48,"return":36,"left":123,"right":124,"up":126,"down":125,"pageup":116,"pagedown":121]
                guard let code=codes[name] else { throw VoiceEditor.problem("Unsupported key.") }
                try VoiceEditor.requireFront(pid:pid,window:window)
                SaveRecovery.key(code,flags:name=="backtab" ? .maskShift : [])
                finishVoiceAction("Key sent to the current window.",token:token);return
            }
            if case .press(let chord)=command {
                try VoiceEditor.requireFront(pid:pid,window:window)
                SaveRecovery.key(chord.code,flags:chord.flags)
                finishVoiceAction("Pressed \(chord.label).",token:token);return
            }
            if case .addWord(nil)=command {
                let word=try voiceEditor.thatText(pid:pid,window:window).trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters))
                finishVocabulary(word,add:true,token:token);return
            }
            if case .readAloud(let scope)=command {
                let source=scope == .document ? voiceEditor.documentText(pid:pid,window:window) : try voiceEditor.thatText(pid:pid,window:window)
                guard var text=source?.trimmingCharacters(in:.whitespacesAndNewlines),!text.isEmpty else { throw VoiceEditor.problem("There is nothing to read.") }
                let partial=text.count>4000
                if partial { text=String(text.prefix(4000)) }
                readAloud(text,token:token,finished:partial ? "Read the first 4,000 characters." : "Finished reading.");return
            }
            if command == .start {
                _=try voiceEditor.field(pid:pid,window:window)
                voiceEditor.target=destination;state.dictating=true;speech?.setDictation(true)
                finishVoiceAction("Dictation mode. Keep talking; say done dictating for commands or scratch that to undo an edit.",token:token);return
            }
            if case .saveAs(let path)=command {
                let saved=try await SaveRecovery.save(path:path,pid:pid,window:window,valid:{self.generation==token},progress:{self.state.detail=$0})
                guard generation==token else { return }
                rememberTarget()
                if state.dictating,let app=targetApp,let window=targetWindowID { voiceEditor.target=(app.processIdentifier,window) }
                finishVoiceAction("Saved and verified: "+saved.path,token:token)
                return
            }
            var selected=command ?? .insert(goal)
            if case .spell(let word)=selected { selected = .insert(word) }
            if case .insert(let text)=selected {
                let literal=["type exactly ","literal text "].contains { goal.lowercased().hasPrefix($0) }
                try voiceEditor.insert(text,pid:pid,window:window,spacing:!literal)
            } else { try voiceEditor.edit(selected,pid:pid,window:window) }
            let result=keptAsText ? "Typed as text; it did not match a command. Say scratch that to remove it. " : "Text updated and verified. "
            finishVoiceAction(result+(state.dictating ? "Keep dictating, or say done dictating." : "Ready for your next request."),token:token)
        } catch {
            // Save As and app switches change what is in front, so their failures still stop queued requests.
            let changesFront=switch command { case .saveAs?,.openApp?: true; default: false }
            if state.dictating && !changesFront { dictationProblem(error.localizedDescription,token:token) }
            else if generation==token { fail(error.localizedDescription) }
        }
        }
        return true
    }
    /// Mutes the microphone while speaking and for a short tail afterwards, so the room falls quiet
    /// before listening resumes. Escape or the hotkey stops reading along with the session.
    func readAloud(_ text:String,token:UUID,finished:String) {
        let reading=UUID();readingToken=reading
        speech?.setMuted(true)
        state.phase="Reading aloud";state.detail="Reading aloud. The microphone is paused; press Escape to stop."
        speechOutput.speak(text) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [weak self] in
                guard let self,self.readingToken==reading else { return }
                self.readingToken=nil;self.speech?.setMuted(false)
                self.finishVoiceAction(finished,token:token)
            }
        }
    }
    func stopReading() {
        guard readingToken != nil else { return }
        readingToken=nil;speechOutput.stop();speech?.setMuted(false)
    }
    func finishVocabulary(_ word:String,add:Bool,token:UUID) {
        let changed=add ? state.addVocabulary(word) : state.removeVocabulary(word)
        let name="“"+word.trimmingCharacters(in:.whitespacesAndNewlines)+"”"
        let result=add ? (changed ? "Added \(name) to your vocabulary." : "\(name) is already in your vocabulary, or is not a single word or name.")
                       : (changed ? "Removed \(name) from your vocabulary." : "\(name) is not in your vocabulary.")
        finishVoiceAction(result,token:token)
    }
    /// Dictation keeps listening after a failed phrase; sentences spoken after it stay queued.
    func dictationProblem(_ message:String,token:UUID) {
        guard generation==token else { return }
        commands.skipActive();state.waitingRequests=commands.pending
        state.busy=false;state.phase="Dictating · needs attention";state.detail=message+" Still dictating."
        DispatchQueue.main.async { [weak self] in self?.drainCommands() }
    }
    func finishVoiceAction(_ message:String,token:UUID) {
        guard generation==token else { return }
        commands.finish(success:true,resolved:originalGoal);state.waitingRequests=commands.pending
        state.busy=false;state.phase=state.recording ? "Listening" : "Finished";state.detail=message;state.completedAt=Date()
        DispatchQueue.main.async { [weak self] in self?.drainCommands() }
        if !state.dictating { scheduleAutoClose() }
    }
}
