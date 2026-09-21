import AppKit
import Foundation

// Exercise the production AppDelegate's failure/cancellation paths without recording audio.
@main struct SessionTests {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let owner=AppDelegate()
        owner.panel=FloatingPanel(contentRect:.zero,styleMask:[.borderless],backing:.buffered,defer:false)
        precondition(!owner.panel.canBecomeKey,"The voice strip must never capture keyboard focus from the working app")
        precondition(HostKeyboard.codes["arbitrary_command"]==nil)
        precondition(!HostKeyboard.focus(["role":"AXButton"],pid:-1),"Only a valid observed editable field can receive targeted keyboard input")
        owner.cursor=NSWindow(contentRect:.zero,styleMask:[.borderless],backing:.buffered,defer:false)
        let capture=SpeechCapture()
        capture.running=true; capture.segmenter=SpeechSegmenter(sampleRate:16000)
        owner.speech=capture; owner.state.recording=true; owner.state.busy=true
        precondition(owner.commands.enqueue("Open Safari"))
        _=owner.commands.next();owner.commands.finish(success:true)
        precondition(owner.commands.enqueue("Failed command"));_=owner.commands.next()
        precondition(owner.commands.enqueue("Dependent follow-up"))
        let oldVoice=owner.voiceGeneration;let oldAudio=owner.audioEpoch;let oldWork=owner.generation
        let wav=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
        try Data([1,2,3]).write(to:wav);owner.audioQueue=[wav]
        owner.fail("Synthetic recoverable failure")
        precondition(owner.state.recording && owner.speech === capture && capture.running,
                     "Command failure must keep the same microphone capture alive")
        precondition(owner.voiceGeneration==oldVoice && owner.audioEpoch != oldAudio && owner.generation != oldWork,
                     "Discard stale audio and worker callbacks without replacing the voice session")
        precondition(owner.commands.active==nil && owner.commands.pending.isEmpty && !owner.state.busy)
        precondition(owner.commands.context==["Open Safari"],"Keep earlier successful context")
        precondition(!FileManager.default.fileExists(atPath:wav.path) && owner.audioQueue.isEmpty)
        precondition(owner.commands.enqueue("Next instruction"),"Accept speech after recovery")
        owner.discardPendingAudio()
        precondition(owner.speech === capture && owner.state.recording,"Clarification must not restart the engine")
        // Queue edits must never relabel the active task or lose a typed draft.
        owner.commands.discardPending()
        precondition(owner.commands.enqueue("Current request"));_=owner.commands.next()
        owner.state.command="Current request";owner.state.busy=true
        owner.state.requestDraft="Typed follow-up";owner.runCommand()
        owner.acceptInstruction("Spoken follow-up")
        precondition(owner.commands.pending==["Typed follow-up","Spoken follow-up"])
        precondition(owner.state.waitingRequests==owner.commands.pending && owner.state.queued==2)
        precondition(owner.state.command=="Current request" && owner.state.requestDraft.isEmpty)
        owner.state.requestDraft="Unsubmitted draft"
        let clearingGeneration=owner.generation
        owner.acceptInstruction("Clear the queue!")
        precondition(owner.commands.pending.isEmpty && owner.state.waitingRequests.isEmpty)
        precondition(owner.commands.active=="Current request" && owner.generation==clearingGeneration && owner.state.busy)
        precondition(owner.state.requestDraft=="Unsubmitted draft","Clearing submitted requests must preserve an unsubmitted draft")
        owner.acceptInstruction("Dependent request")
        let cancelledWork=owner.generation;let sameMicrophone=owner.voiceGeneration
        owner.acceptInstruction("Cancel that.")
        precondition(owner.state.recording && owner.speech === capture && owner.voiceGeneration==sameMicrophone)
        precondition(owner.generation != cancelledWork && !owner.state.busy && owner.commands.active==nil)
        precondition(owner.commands.pending.isEmpty && owner.state.waitingRequests.isEmpty && owner.state.requestDraft.isEmpty)
        precondition(owner.commands.context==["Open Safari"],"Task cancellation preserves successful session context")
        precondition(!owner.state.needsAttention && owner.state.detail.contains("Changes already made are kept"))
        let cancelledDetail=owner.state.detail
        owner.receive(["event":"done","success":true,"text":"Late completion"],token:cancelledWork)
        precondition(owner.state.detail==cancelledDetail,"Late completion must not overwrite cancellation")
        owner.state.question="Which folder?";owner.state.answer="Never mind"
        owner.submitAnswer(owner.state.answer)
        precondition(owner.state.question.isEmpty && owner.state.recording && owner.dialogue.isEmpty)
        // The capture is synthetic (no installed audio tap), so detach it before explicit stop.
        owner.speech=nil;owner.stop(close:true)
        precondition(!owner.state.recording && owner.commands.context.isEmpty && owner.commands.pending.isEmpty)
        precondition(PilotCopy.issue("The model service took too long to reply.")=="Slow connection. Please try again.")
        precondition(PilotCopy.issue("Cua can see this window, but its controls are unavailable.")=="This window needs your help.")
        precondition(PilotCopy.issue("This part of the task reached its step limit.")=="Please split this into smaller requests.")
        precondition(PilotCopy.hasConfiguredKey("OPENROUTER_API_KEY",in:"export OPENROUTER_API_KEY = \"test\""))
        precondition(!PilotCopy.hasConfiguredKey("OPENROUTER_API_KEY",in:"# OPENROUTER_API_KEY=test"))
        precondition(!PilotCopy.hasConfiguredKey("OPENROUTER_API_KEY",in:"OPENROUTER_API_KEY=\"\""))
        precondition(owner.state.shortcutWords=="Control + Option + Space")
        let now=Date()
        owner.state.recording=true;owner.state.question="Which Tom?";owner.state.lastSpeech=now.addingTimeInterval(-2)
        precondition(!owner.state.showsWaves(at:now),"A pending question replaces the waveform during silence")
        owner.state.lastSpeech=now
        precondition(owner.state.showsWaves(at:now),"Speaking restores the waveform")
        precondition(owner.state.question=="Which Tom?","Showing waves must preserve the pending clarification")
        precondition(!owner.state.showsWaves(at:now.addingTimeInterval(1)),"Question becomes visible after speech pauses")
        owner.state.recording=false;precondition(!owner.state.showsWaves(at:now))
        let movedFrame=NSRect(x:120,y:180,width:280,height:44)
        owner.panel.setFrame(movedFrame,display:false);owner.panelPositioned=true;owner.showPanel(key:false)
        precondition(owner.panel.frame==movedFrame,"Progress updates must preserve the user's panel position")
        owner.receive(["event":"capture"],token:owner.generation)
        precondition(owner.panel.isVisible && owner.panel.frame==movedFrame,"Capturing must not hide or move the voice strip")
        precondition(CursorTiming.ease(0)==0 && CursorTiming.ease(1)==1)
        var previous=0.0
        for step in 0...100 {
            let value=CursorTiming.ease(Double(step)/100)
            precondition(value>=previous && value<=1,"Cursor easing must never reverse or overshoot")
            previous=value
        }
        precondition(CursorTiming.duration(distance:1,reducedMotion:false)==0.24)
        precondition(CursorTiming.duration(distance:5000,reducedMotion:false)==0.52)
        precondition(CursorTiming.duration(distance:5000,reducedMotion:true)==0)
        owner.cursor.setContentSize(CursorView.size)
        owner.cursor.contentView=CursorView(frame:NSRect(origin:.zero,size:CursorView.size))
        if let index=CommandLine.arguments.firstIndex(of:"--cursor-preview"),CommandLine.arguments.count>index+1,
           let view=owner.cursor.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]))
        }
        if let view=owner.cursor.contentView as? CursorView {
            let screen=NSRect(x:0,y:0,width:1000,height:700)
            for point in [NSPoint(x:5,y:100),NSPoint(x:995,y:100)] {
                view.placeBadge(at:point,on:screen)
                let left=point.x-CursorView.hotspot.x+view.badgeOrigin.x
                precondition(left>=6 && left+154<=994,"Badge stays visible at either screen edge")
            }
            view.placeBadge(at:NSPoint(x:500,y:10),on:screen)
            precondition(view.badgeOrigin.y+26<CursorView.hotspot.y,"Bottom-edge badge sits above the hotspot")
        }
        let motion=CursorMotion(window:owner.cursor)
        var arrived=false
        motion.move(to:NSPoint(x:450,y:350)) { arrived=true }
        if !motion.reducedMotion { precondition(!arrived,"Input must wait until the cursor arrives") }
        RunLoop.current.run(until:Date().addingTimeInterval(0.6))
        precondition(arrived && owner.cursor.frame.origin==NSPoint(x:450-CursorView.hotspot.x,y:350-CursorView.size.height+CursorView.hotspot.y))
        motion.actionFinished()
        RunLoop.current.run(until:Date().addingTimeInterval(0.9))
        motion.move(to:NSPoint(x:100,y:100)) { }
        RunLoop.current.run(until:Date().addingTimeInterval(0.6))
        precondition(owner.cursor.alphaValue==1,"A previous fade must not hide the next action")
        var cancelledArrival=false
        motion.move(to:NSPoint(x:1100,y:650)) { cancelledArrival=true }
        motion.hide()
        RunLoop.current.run(until:Date().addingTimeInterval(0.6))
        precondition(!owner.cursor.isVisible)
        if !motion.reducedMotion { precondition(!cancelledArrival,"Stop must cancel the pending action") }
        let oldClosePreference=UserDefaults.standard.object(forKey:"closeWhenDone")
        defer {
            if let oldClosePreference { UserDefaults.standard.set(oldClosePreference,forKey:"closeWhenDone") }
            else { UserDefaults.standard.removeObject(forKey:"closeWhenDone") }
        }
        owner.state.question="";owner.state.phase="Listening";owner.state.lastSpeech=now.addingTimeInterval(-3)
        owner.state.closeWhenDone=true
        precondition(owner.autoCloseReady(at:now),"Successful idle work can close when enabled")
        owner.activityWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:100,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        owner.activityWindow?.orderFrontRegardless()
        precondition(!owner.autoCloseReady(at:now),"Never auto-close while the user is typing in the conversation")
        owner.activityWindow?.orderOut(nil)
        owner.state.closeWhenDone=false
        precondition(!owner.autoCloseReady(at:now),"Stay-open preference must prevent automatic close")
        owner.state.closeWhenDone=true;owner.state.lastSpeech=now
        precondition(!owner.autoCloseReady(at:now),"Do not close over new speech")
        owner.state.lastSpeech=now.addingTimeInterval(-3);owner.state.question="Which Tom?"
        precondition(!owner.autoCloseReady(at:now),"Never close over a clarification")
        owner.state.question="";owner.state.phase="Listening · needs attention"
        precondition(!owner.autoCloseReady(at:now),"Never close after an error")
        owner.state.phase="Listening";precondition(owner.commands.enqueue("Follow-up"))
        precondition(!owner.autoCloseReady(at:now),"Do not drop a queued follow-up")
        owner.commands.cancel();owner.state.recording=true;owner.state.closeWhenDone=false
        owner.scheduleAutoClose()
        RunLoop.current.run(until:Date().addingTimeInterval(2.1))
        precondition(owner.state.recording,"Stay-open mode retains the microphone")
        owner.state.closeWhenDone=true;owner.state.detail="Finished test command"
        owner.scheduleAutoClose()
        RunLoop.current.run(until:Date().addingTimeInterval(2.1))
        precondition(!owner.state.recording && !owner.panel.isVisible,"Auto-close stops capture and hides the strip")
        precondition(owner.state.detail=="Finished test command","Keep the result for the activity window")
        owner.startingVoice=true;owner.hotkey()
        precondition(!owner.startingVoice && !owner.panel.isVisible,"A second hotkey cancels microphone startup")
        // Opening the editor waits for the worker's action boundary. No focus
        // is stolen mid-input, and cancelling a held checkpoint closes its pipe.
        owner.state.busy=true;owner.state.recording=false
        let testProcess=Process();let testInput=Pipe();let testOutput=Pipe()
        testProcess.executableURL=URL(fileURLWithPath:"/bin/cat")
        testProcess.standardInput=testInput;testProcess.standardOutput=testOutput
        try testProcess.run();owner.task=testProcess;owner.input=testInput
        precondition(owner.requestReview("activity"))
        precondition(owner.state.reviewing && !owner.state.reviewReady && owner.activityWindow?.isVisible != true)
        owner.receive(["event":"checkpoint"],token:owner.generation)
        precondition(owner.state.reviewReady && owner.reviewToken==owner.generation && owner.activityWindow?.isVisible==true)
        precondition(owner.handleSessionInstruction("Resume the task."))
        precondition(!owner.state.reviewing && owner.reviewToken==nil && owner.activityWindow?.isVisible != true)
        let reviewAck=try testOutput.fileHandleForReading.read(upToCount:9)
        precondition(reviewAck==Data("continue\n".utf8))
        precondition(owner.requestReview("activity"))
        owner.receive(["event":"checkpoint"],token:owner.generation)
        let reviewGeneration=owner.generation
        owner.cancelCurrentTask()
        precondition(!owner.state.reviewing && owner.reviewToken==nil && owner.task==nil)
        owner.receive(["event":"checkpoint"],token:reviewGeneration)
        precondition(owner.reviewToken==nil,"A late checkpoint must not restart cancelled work")
        testProcess.waitUntilExit()
        owner.activityWindow?.orderOut(nil)
        let beforeStaleKey=owner.state.detail
        owner.receive(["event":"host_key","pid":-1,"key":"return"],token:UUID())
        precondition(owner.state.detail==beforeStaleKey,"Cancelled generations must never issue keyboard input")
        owner.receive(["event":"host_key","pid":-1,"key":"return"],token:owner.generation)
        precondition(owner.state.detail.contains("active app changed"),"Host keyboard input must reject a different foreground app")
        print("Session tests passed: recovery, cancellation, continuous voice, auto-close, strip visibility, cursor easing, arrival gating, and fade cancellation.")
    }
}
