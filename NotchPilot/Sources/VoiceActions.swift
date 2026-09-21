import AppKit

extension AppDelegate {
    @discardableResult func handleLocalVoiceCommand(_ goal:String) -> Bool {
        let command=VoiceEditCommand.parse(goal)
        guard command != nil || state.dictating else { return false }
        rememberTarget()
        let token=UUID();generation=token;state.busy=true;state.cost=0
        if state.preview { finishVoiceAction("Preview: voice editing would run locally. No document changed.",token:token);return true }
        Task { @MainActor in
        do {
            activityWindow?.orderOut(nil);targetApp?.activate(options:[])
            try await Task.sleep(nanoseconds:150_000_000)
            guard generation==token else { return }
            if command == .help {
                finishVoiceAction("Start dictating · Done dictating · New paragraph · Select [words] · Replace [words] with [words] · Scratch that · Go to beginning/end · Save as ~/Desktop/Note.txt · Go to sleep · Wake up. Use command mode for other app tasks.",token:token)
                state.activityDetails=true;presentActivity();return
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
            let currentTarget=targetApp.flatMap { app in targetWindowID.map { (pid:app.processIdentifier,window:$0) } }
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
            let selected=command ?? .insert(goal)
            if case .insert(let text)=selected {
                let literal=["type exactly ","literal text "].contains { goal.lowercased().hasPrefix($0) }
                try voiceEditor.insert(text,pid:pid,window:window,spacing:!literal)
            } else { try voiceEditor.edit(selected,pid:pid,window:window) }
            finishVoiceAction("Text updated and verified. "+(state.dictating ? "Keep dictating, or say done dictating." : "Ready for your next request."),token:token)
        } catch { if generation==token { fail(error.localizedDescription) } }
        }
        return true
    }
    func finishVoiceAction(_ message:String,token:UUID) {
        guard generation==token else { return }
        commands.finish(success:true,resolved:originalGoal);state.waitingRequests=commands.pending
        state.busy=false;state.phase=state.recording ? "Listening" : "Finished";state.detail=message;state.completedAt=Date()
        DispatchQueue.main.async { [weak self] in self?.drainCommands() }
        if !state.dictating { scheduleAutoClose() }
    }
}
