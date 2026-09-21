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
        precondition(VoiceEditCommand.parse("Open TextEdit.") == .openApp("com.apple.TextEdit"))
        precondition(VoiceEditCommand.parse("Replace purple with blue.") == .replace("purple","blue"))
        precondition(VoiceEditCommand.parse("Next field") == .key("tab"))
        precondition(VoiceEditCommand.parse("Press shift tab") == .key("backtab"))
        precondition(VoiceEditCommand.parse("Open arbitrary unknown app") == nil)
        precondition(VoiceEditCommand.parse("Start dictating!") == .start)
        precondition(VoiceEditCommand.parse("Done dictating.") == .end)
        precondition(VoiceEditCommand.parse("Scratch that.") == .scratch)
        precondition(VoiceEditCommand.parse("New paragraph") == .insert("\n\n"))
        precondition(VoiceEditCommand.parse("Type exactly stop") == .insert("stop"))
        precondition(VoiceEditCommand.parse("Replace purple with blue") == .replace("purple","blue"))
        precondition(VoiceEditCommand.parse("Save as My Note.txt on my desktop") == .saveAs("~/Desktop/My Note.txt"))
        precondition(VoiceEditCommand.parse("Save as /tmp/name.") == .saveAs("/tmp/name."))
        precondition(VoiceEditCommand.parse("The boy said stop.")==nil)
        // While dictating, prose that only resembles a command stays prose, as in Dragon and Voice Control.
        let bike="A little boy rode his purple bike."
        precondition(VoiceEditCommand.parse("Change is hard to accept.")!.isProse(in:bike))
        precondition(VoiceEditCommand.parse("Select the best option for your family.")!.isProse(in:bike))
        precondition(!VoiceEditCommand.parse("Replace Purple with blue.")!.isProse(in:bike))
        precondition(!VoiceEditCommand.parse("Select purple bike")!.isProse(in:nil),"Unreadable text reports the editor problem instead of guessing")
        precondition(VoiceEditCommand.parse("Save as much as you can on groceries.")!.isProse(in:bike))
        precondition(!VoiceEditCommand.parse("Save as My Note.txt on my desktop")!.isProse(in:bike))
        precondition(!VoiceEditCommand.parse("Save as /tmp/name.")!.isProse(in:bike))
        precondition(!VoiceEditCommand.scratch.isProse(in:""))
        // Whisper labels non-speech in several styles; none of it may become text or a request.
        for noise in ["[BLANK_AUDIO]","(water splashing)","*gunshot*","[ Sound Effects ]","♪ ♪","[Music] (applause)","  "] {
            precondition(SpeechText.isNonSpeech(noise),noise)
        }
        for speech in ["Hello (laughs)","Thank you.","5","*really* good"] { precondition(!SpeechText.isNonSpeech(speech),speech) }
        for phantom in ["You","Thank you.","Thanks for watching!"] {
            precondition(SpeechText.isNonSpeech(phantom,dictation:false),"Whisper's classic silence hallucinations are not commands")
            precondition(!SpeechText.isNonSpeech(phantom,dictation:true),"…but may be real dictation")
        }
        let commandPrompt="Voice commands for a Mac. Open TextEdit. Write a sentence. Type hello world."
        precondition(SpeechText.prompt(dictation:false,vocabulary:[],context:"ignored")==commandPrompt)
        precondition(SpeechText.prompt(dictation:false,vocabulary:["NotchPilot","Kubernetes"],context:"")==commandPrompt+" Vocabulary: NotchPilot, Kubernetes.")
        precondition(SpeechText.prompt(dictation:true,vocabulary:[],context:"")=="","Dictation without context keeps Whisper unbiased")
        precondition(SpeechText.prompt(dictation:true,vocabulary:["NotchPilot"],context:"A little boy rode his")=="NotchPilot. A little boy rode his")
        let bounded=SpeechText.prompt(dictation:true,vocabulary:[],context:String(repeating:"word ",count:400)+"tail end")
        precondition(bounded.count<=600 && bounded.hasPrefix("word") && bounded.hasSuffix("tail end"),"Context is the latest text, starting on a word")
        precondition(SpeechText.applyVocabulary("open notchpilot and kubernetes",["NotchPilot","Kubernetes"])=="open NotchPilot and Kubernetes")
        precondition(SpeechText.applyVocabulary("notchpilots",["NotchPilot"])=="notchpilots","Only whole words")
        let rode=DictationEdit(pid:1,window:2,field:AXUIElementCreateSystemWide(),before:"",after:"A little boy rode his.",
                               range:NSRange(location:0,length:0),inserted:"A little boy rode his.")
        precondition(VoiceEditor.joinsSentence("purple bike.",value:rode.after,selection:NSRange(location:22,length:0),previous:rode),
                     "A lowercase continuation replaces the period Whisper added to the previous phrase")
        precondition(!VoiceEditor.joinsSentence("Purple bike.",value:rode.after,selection:NSRange(location:22,length:0),previous:rode))
        precondition(!VoiceEditor.joinsSentence("purple bike.",value:rode.after+" ",selection:NSRange(location:23,length:0),previous:rode),"Edited text is left alone")
        precondition(!VoiceEditor.joinsSentence("purple bike.",value:rode.after,selection:NSRange(location:10,length:0),previous:rode),"Only at the end of the last phrase")
        let question=DictationEdit(pid:1,window:2,field:AXUIElementCreateSystemWide(),before:"",after:"Is it blue?",
                                   range:NSRange(location:0,length:0),inserted:"Is it blue?")
        precondition(!VoiceEditor.joinsSentence("or red?",value:question.after,selection:NSRange(location:11,length:0),previous:question),"Only a period")
        // Dragon-style editing, spelling, key chords, and vocabulary by voice.
        precondition(VoiceEditCommand.parse("Select previous word.") == .selectRelative(.word,.previous,1))
        precondition(VoiceEditCommand.parse("Select the last three words") == .selectRelative(.word,.previous,3))
        precondition(VoiceEditCommand.parse("Delete last sentence.") == .deleteRelative(.sentence,.previous,1))
        precondition(VoiceEditCommand.parse("Select next paragraph") == .selectRelative(.paragraph,.next,1))
        precondition(VoiceEditCommand.parse("Delete the previous 2 words.") == .deleteRelative(.word,.previous,2))
        precondition(VoiceEditCommand.parse("Delete that.") == .deleteThat)
        precondition(VoiceEditCommand.parse("Select that") == .selectThat)
        precondition(VoiceEditCommand.parse("Select all.") == .selectAll)
        precondition(VoiceEditCommand.parse("Capitalize that.") == .transformThat(.capitalized))
        precondition(VoiceEditCommand.parse("All caps that") == .transformThat(.uppercase))
        precondition(VoiceEditCommand.parse("No caps that") == .transformThat(.lowercase))
        precondition(VoiceEditCommand.parse("Insert after purple bike.") == .insertAt(before:false,"purple bike"))
        precondition(VoiceEditCommand.parse("Insert before the boy") == .insertAt(before:true,"the boy"))
        precondition(VoiceEditCommand.parse("Insert before the boy")!.isProse(in:"No match here."),"A missing anchor is prose")
        precondition(VoiceEditCommand.parse("Spell see a tea.") == .spell("cat"),"Whisper hears spoken letters as words")
        precondition(VoiceEditCommand.parse("Spell C-A-T.") == .spell("cat"))
        precondition(VoiceEditCommand.parse("Spell cap j o h n") == .spell("John"))
        precondition(VoiceEditCommand.parse("Spell all caps n a s a") == .spell("NASA"))
        precondition(VoiceEditCommand.parse("Spell Charlie Alpha Tango dash 7") == .spell("cat-7"))
        precondition(VoiceEditCommand.parse("Spell j at example dot com") == .spell("j@example.com"))
        precondition(VoiceEditCommand.parse("Spell out the plan.") == nil,"Ordinary words are not spelling")
        precondition(VoiceEditCommand.parse("Add that to vocabulary.") == .addWord(nil))
        precondition(VoiceEditCommand.parse("Add the word Siobhan.") == .addWord("Siobhan"))
        precondition(VoiceEditCommand.parse("Add Kubernetes to my vocabulary") == .addWord("Kubernetes"))
        precondition(VoiceEditCommand.parse("Remove the word Siobhan.") == .removeWord("Siobhan"))
        precondition(VoiceEditCommand.parse("Press Command Shift S.") == .press(KeyChord(code:1,command:true,shift:true)))
        precondition(VoiceEditCommand.parse("press command-s") == .press(KeyChord(code:1,command:true)))
        precondition(VoiceEditCommand.parse("Hit escape.") == .press(KeyChord(code:53)))
        precondition(VoiceEditCommand.parse("Press control option space") == .press(KeyChord(code:49,option:true,control:true)))
        precondition(VoiceEditCommand.parse("Press F5") == .press(KeyChord(code:96)))
        precondition(VoiceEditCommand.parse("Press command one") == .press(KeyChord(code:18,command:true)))
        precondition(VoiceEditCommand.parse("Press enter") == .key("return"),"Existing key names keep their routes")
        for prose in ["Press the button firmly.","Press command shift","Press a b"] { precondition(VoiceEditCommand.parse(prose)==nil,prose) }
        precondition(KeyChord(code:1,command:true,shift:true).label=="⇧⌘S")
        let boy="A boy rode his bike." as NSString,end=NSRange(location:boy.length,length:0)
        func text(_ r:NSRange?,_ s:NSString=boy) -> String? { r.map { s.substring(with:$0) } }
        precondition(text(TextCommands.range(.word,.previous,1,in:boy as String,selection:end))=="bike.")
        precondition(text(TextCommands.range(.word,.previous,2,in:boy as String,selection:end))=="his bike.")
        precondition(text(TextCommands.range(.word,.next,1,in:boy as String,selection:NSRange(location:0,length:0)))=="A")
        precondition(text(TextCommands.range(.word,.next,1,in:boy as String,selection:NSRange(location:5,length:0)))=="rode","Skip the space before the next word")
        precondition(TextCommands.range(.word,.previous,1,in:boy as String,selection:NSRange(location:0,length:0))==nil,"Nothing before the start")
        let deleted=TextCommands.forDeletion(TextCommands.range(.word,.previous,1,in:boy as String,selection:end)!,in:boy as String)
        precondition(boy.replacingCharacters(in:deleted,with:"")=="A boy rode his","Deleting the last word removes its space too")
        let middle=TextCommands.forDeletion(NSRange(location:6,length:4),in:boy as String)
        precondition(boy.replacingCharacters(in:middle,with:"")=="A boy his bike.","No double space after deleting a middle word")
        let two="One. Two three." as NSString,twoEnd=NSRange(location:two.length,length:0)
        precondition(text(TextCommands.range(.sentence,.previous,1,in:two as String,selection:twoEnd),two)=="Two three.")
        precondition(text(TextCommands.range(.sentence,.next,1,in:two as String,selection:NSRange(location:0,length:0)),two)=="One.")
        let lastSentence=TextCommands.forDeletion(TextCommands.range(.sentence,.previous,1,in:two as String,selection:twoEnd)!,in:two as String)
        precondition(two.replacingCharacters(in:lastSentence,with:"")=="One.")
        let paragraphs="First para.\n\nSecond para." as NSString
        precondition(text(TextCommands.range(.paragraph,.previous,1,in:paragraphs as String,selection:NSRange(location:paragraphs.length,length:0)),paragraphs)=="Second para.")
        precondition(TextCommands.transform(" purple bike's wheel.",.capitalized)==" Purple Bike's Wheel.")
        precondition(TextCommands.transform("iPhone case",.capitalized)=="IPhone Case","Only first letters change")
        precondition(TextCommands.transform("Loud",.uppercase)=="LOUD" && TextCommands.transform("QUIET",.lowercase)=="quiet")
        let savedVocabulary=owner.state.vocabularyText
        owner.state.vocabularyText="NotchPilot"
        precondition(owner.state.addVocabulary(" Siobhan ") && owner.state.vocabulary==["NotchPilot","Siobhan"])
        precondition(!owner.state.addVocabulary("siobhan"),"No duplicates")
        precondition(!owner.state.addVocabulary("two, words") && !owner.state.addVocabulary(""),"One word or name at a time")
        precondition(owner.state.removeVocabulary("SIOBHAN") && owner.state.vocabulary==["NotchPilot"] && !owner.state.removeVocabulary("absent"))
        owner.state.vocabularyText=savedVocabulary
        // Numbers, click by name, and the mouse grid.
        precondition(VoiceEditCommand.parse("Show numbers.") == .showNumbers)
        precondition(VoiceEditCommand.parse("Hide numbers") == .hideOverlay && VoiceEditCommand.parse("Close grid.") == .hideOverlay)
        precondition(VoiceEditCommand.parse("Click 5.") == .choose(5,.click))
        precondition(VoiceEditCommand.parse("Double click 3") == .choose(3,.doubleClick))
        precondition(VoiceEditCommand.parse("Right-click twelve.") == .choose(12,.rightClick))
        precondition(VoiceEditCommand.parse("5") == .number(5) && VoiceEditCommand.parse("Five.") == .number(5))
        precondition(VoiceEditCommand.parse("Number 14") == .number(14) && VoiceEditCommand.parse("For.") == .number(4))
        precondition(VoiceEditCommand.parse("Click Save.") == .clickNamed("save",.click))
        precondition(VoiceEditCommand.parse("Double-click Read Me") == .clickNamed("read me",.doubleClick))
        precondition(VoiceEditCommand.parse("Mouse grid") == .mouseGrid && VoiceEditCommand.parse("Show grid.") == .mouseGrid)
        precondition(VoiceEditCommand.parse("Click.") == .pointerClick(.click) && VoiceEditCommand.parse("Right click") == .pointerClick(.rightClick))
        precondition(VoiceEditCommand.parse("Go back.") == .gridBack)
        let dialog=["Save","Save As…","Cancel","Don’t Save","Search"]
        precondition(PointTargets.matches("save",labels:dialog)==[0],"An exact name wins")
        precondition(PointTargets.matches("save as",labels:dialog)==[1])
        precondition(PointTargets.matches("don't save",labels:dialog)==[3],"Apostrophes do not matter")
        precondition(PointTargets.matches("sea",labels:dialog)==[4],"A unique prefix")
        precondition(PointTargets.matches("sav",labels:dialog)==[0,1],"Ambiguous prefixes return every match")
        precondition(PointTargets.matches("delete",labels:dialog).isEmpty)
        precondition(PointTargets.windowButtonName("AXCloseButton")=="Close" && PointTargets.windowButtonName("AXZoomButton")=="Zoom","Title-bar buttons get their names, not their tooltips")
        precondition(PointTargets.windowButtonName("AXFullScreenButton")=="Full Screen" && PointTargets.windowButtonName("AXSearchField")==nil)
        let ordered=PointTargets.readingOrder([CGRect(x:300,y:12,width:20,height:20),CGRect(x:10,y:200,width:20,height:20),CGRect(x:10,y:10,width:20,height:20)])
        precondition(ordered==[2,0,1],"Numbers read left to right, then top to bottom")
        var grid=MouseGrid(CGRect(x:0,y:0,width:900,height:600))
        precondition(grid.zoom(5) && grid.rect==CGRect(x:300,y:200,width:300,height:200) && grid.center==CGPoint(x:450,y:300))
        precondition(grid.zoom(1) && grid.rect==CGRect(x:300,y:200,width:100,height:200/3.0),"Cell 1 is the top left")
        precondition(grid.back() && grid.rect==CGRect(x:300,y:200,width:300,height:200) && !grid.zoom(0) && !grid.zoom(10))
        precondition(grid.back() && !grid.back(),"Back stops at the whole screen")
        precondition(VoiceEditCommand.parse("Read that.") == .readAloud(.that) && VoiceEditCommand.parse("Read it back") == .readAloud(.that))
        precondition(VoiceEditCommand.parse("Read the document.") == .readAloud(.document) && VoiceEditCommand.parse("Read everything") == .readAloud(.document))
        precondition(VoiceEditCommand.parse("Read the paper tomorrow.") == nil,"Only exact read-back phrases")
        // Reading aloud mutes the microphone and drops any half-heard phrase, so NotchPilot never hears itself.
        let reader=SpeechCapture()
        reader.running=true;reader.segmenter=SpeechSegmenter(sampleRate:16000);reader.segmenter?.active=true
        reader.setMuted(true)
        precondition(reader.muted && !reader.hasPendingSpeech,"Muting discards partial speech")
        reader.setMuted(false)
        precondition(!reader.muted)
        // Every phrase the in-app help advertises must work.
        let sessionPhrases=["Go to sleep","Wake up","Cancel that","Stop"]
        for (_,examples) in VoiceHelp.sections {
            for phrase in examples where !sessionPhrases.contains(phrase) {
                precondition(VoiceEditCommand.parse(phrase) != nil,"Help advertises a phrase that does not parse: "+phrase)
            }
        }
        precondition(VoiceCommandQueue.isStop("Stop") && VoiceCommandQueue.isCancelTask("Cancel that"))
        precondition(VoiceHelp.text.contains("Show numbers") && VoiceHelp.text.components(separatedBy:"\n").count==VoiceHelp.sections.count)
        precondition(QAInbox(arguments:["NotchPilot"])==nil,"QA automation is off unless explicitly launched with --qa-inbox")
        let inboxDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("qa-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:inboxDirectory,withIntermediateDirectories:true)
        for name in ["02-b.cmd","01-a.cmd","status.json","notes.txt"] { try Data("x".utf8).write(to:inboxDirectory.appendingPathComponent(name)) }
        precondition(QAInbox(arguments:["NotchPilot","--qa-inbox",inboxDirectory.path])?.directory.path==inboxDirectory.path)
        precondition(QAInbox.pending(in:inboxDirectory).map(\.lastPathComponent)==["01-a.cmd","02-b.cmd"],"Only .cmd files, in name order")
        try? FileManager.default.removeItem(at:inboxDirectory)
        precondition(VoiceEditor.uniqueRange("cat",in:"A CAT") == NSRange(location:2,length:3))
        precondition(VoiceEditor.uniqueRange("cat",in:"cat cat")==nil)
        precondition(VoiceEditor.uniqueRange("missing",in:"text")==nil)
        precondition(VoiceEditor.uniqueRange("hi",in:"😀 hi") == NSRange(location:3,length:2))
        do { _=try SaveRecovery.destination("relative.txt");preconditionFailure("Relative save must not guess a folder") } catch {}
        // Verification compares file identity: /tmp is a symlink to /private/tmp, and path standardization
        // strips /private only once a file exists, so string comparison failed for saves under /tmp.
        let savedFile=URL(fileURLWithPath:"/private/tmp/notchpilot-same-\(UUID().uuidString).rtf")
        try Data("x".utf8).write(to:savedFile)
        precondition(SaveRecovery.sameFile(URL(string:"file:///tmp/"+savedFile.lastPathComponent)!,savedFile),"The same file through a symlinked folder")
        precondition(!SaveRecovery.sameFile(savedFile,URL(fileURLWithPath:"/private/tmp/notchpilot-missing.rtf")),"A missing file never verifies")
        try? FileManager.default.removeItem(at:savedFile)
        precondition(HostKeyboard.codes["arbitrary_command"]==nil)
        precondition(HostKeyboard.insertion("Next sentence.",into:"First.",range:NSRange(location:6,length:0),spacing:true)?.result=="First. Next sentence.")
        precondition(HostKeyboard.insertion("Next",into:"First. ",range:NSRange(location:7,length:0),spacing:true)?.result=="First. Next")
        precondition(HostKeyboard.insertion("X",into:"ab",range:NSRange(location:1,length:0),spacing:true)?.result=="aXb")
        precondition(HostKeyboard.insertion("red",into:"blue bike",range:NSRange(location:0,length:4),spacing:true)?.result=="red bike")
        precondition(HostKeyboard.insertion("Hello",into:"",range:NSRange(location:0,length:0),spacing:true)?.result=="Hello")
        precondition(HostKeyboard.insertion("B",into:"A",range:NSRange(location:1,length:0),spacing:false)?.result=="AB")
        precondition(HostKeyboard.insertion("Hi",into:"😀",range:NSRange(location:2,length:0),spacing:true)?.result=="😀Hi")
        precondition(HostKeyboard.insertion("x",into:"a",range:NSRange(location:2,length:0),spacing:true)==nil)
        precondition(!HostKeyboard.focus(["role":"AXButton"],pid:-1),"Only a valid observed editable field can receive targeted keyboard input")
        owner.cursor=CursorOverlay.makeWindow()
        precondition(!owner.cursor.isOpaque && owner.cursor.backgroundColor.alphaComponent==0 && !owner.cursor.hasShadow,
                     "The production and test cursor must share a transparent, shadowless window")
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
        owner.acceptInstruction("Go to sleep")
        precondition(owner.state.voiceSleeping && owner.state.recording && !owner.state.busy)
        owner.acceptInstruction("These words must be ignored")
        precondition(owner.commands.pending.isEmpty && owner.commands.active==nil)
        owner.acceptInstruction("Wake up")
        precondition(!owner.state.voiceSleeping && owner.state.recording)
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
        precondition(PilotCopy.issue("That file already exists.")=="Choose a different filename.")
        precondition(PilotCopy.issue("Speech recognition took too long.")=="Speech stalled. Please try again.")
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
        if let view=owner.cursor.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            for point in [(0,0),(bitmap.pixelsWide-1,0),(0,bitmap.pixelsHigh-1),(bitmap.pixelsWide-1,bitmap.pixelsHigh-1)] {
                precondition(bitmap.colorAt(x:point.0,y:point.1)?.alphaComponent==0,"Empty cursor space must render transparent")
            }
        } else { preconditionFailure("The cursor must be renderable") }
        if let index=CommandLine.arguments.firstIndex(of:"--cursor-preview"),CommandLine.arguments.count>index+1,
           let view=owner.cursor.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]))
        }
        precondition(CursorView.size.width<=64 && CursorView.size.height<=64,"The cursor is only the pointer, with no NotchPilot badge")
        // The overlay draws badges and outlines only; everything else stays transparent and click-through.
        let overlayView=PointingView(frame:NSRect(x:0,y:0,width:400,height:300))
        overlayView.screenQuartz=CGRect(x:0,y:0,width:400,height:300)
        let sample=PointTarget(element:AXUIElementCreateSystemWide(),pid:0,role:"AXButton",label:"OK",frame:CGRect(x:120,y:100,width:80,height:28),actions:[])
        for (name,value) in [("numbers",Pointing.numbers([sample,PointTarget(element:sample.element,pid:0,role:"AXLink",label:"Help",frame:CGRect(x:220,y:100,width:60,height:20),actions:[])])),
                             ("grid",Pointing.grid(MouseGrid(CGRect(x:0,y:0,width:400,height:300))))] {
            overlayView.pointing=value
            guard let bitmap=overlayView.bitmapImageRepForCachingDisplay(in:overlayView.bounds) else { preconditionFailure("The overlay must render") }
            overlayView.cacheDisplay(in:overlayView.bounds,to:bitmap)
            if let index=CommandLine.arguments.firstIndex(of:"--overlay-preview"),CommandLine.arguments.count>index+1 {
                try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]+"-"+name+".png"))
            }
            let scale=CGFloat(bitmap.pixelsWide)/overlayView.bounds.width
            func alpha(_ x:CGFloat,_ y:CGFloat) -> CGFloat { bitmap.colorAt(x:Int(x*scale),y:Int(y*scale))?.alphaComponent ?? 0 }
            if name=="numbers" {
                precondition(alpha(124,96)>0.5,"A numbered badge sits at the control's top-left corner")
                precondition(alpha(350,250)==0,"Space without controls is transparent")
            } else { precondition(alpha(200,150)>0.5,"Cell 5 is labeled at the grid's center") }
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
        // A hung recognizer must time out once; cancelled callbacks must never insert text.
        let stalled=Runtime(root:"",python:"",worker:"",whisper:"/bin/sleep",model:"10",vad:"/bin/sleep",vadModel:"10",planner:"",qwen:"",downloader:"")
        let recognizer=WhisperSession(requestTimeout:0.12)
        var timedOut=0;var cancelledTranscripts=0
        recognizer.transcribe(runtime:stalled,url:URL(fileURLWithPath:"/tmp/test.wav"),dictation:true) { _ in cancelledTranscripts += 1 }
        recognizer.cancelPending()
        RunLoop.current.run(until:Date().addingTimeInterval(0.18))
        precondition(cancelledTranscripts==0,"Cancelled speech must not return a transcript")
        recognizer.transcribe(runtime:stalled,url:URL(fileURLWithPath:"/tmp/test.wav"),dictation:true) { result in
            if case .failure=result { timedOut += 1 }
        }
        RunLoop.current.run(until:Date().addingTimeInterval(0.3))
        precondition(timedOut==1,"A hung recognizer must fail once and allow restart")
        recognizer.shutdown()
        // A failed dictation phrase reports the problem without dropping speech said after it.
        owner.state.dictating=true;owner.state.recording=true;owner.state.busy=true
        precondition(owner.commands.enqueue("Replace missing words with text"));_=owner.commands.next()
        precondition(owner.commands.enqueue("The next dictated sentence."))
        let spoken=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
        try Data([1,2,3]).write(to:spoken);owner.audioQueue=[spoken]
        let dictationAudio=owner.audioEpoch
        owner.dictationProblem("Stale failure",token:UUID())
        precondition(owner.state.busy && owner.commands.active != nil,"A cancelled phrase must not report a failure")
        owner.dictationProblem("That text is missing.",token:owner.generation)
        precondition(owner.commands.active==nil && owner.commands.pending==["The next dictated sentence."],"Later dictation stays queued")
        precondition(owner.audioQueue==[spoken] && owner.audioEpoch==dictationAudio && FileManager.default.fileExists(atPath:spoken.path),
                     "Speech awaiting transcription is kept")
        precondition(!owner.state.busy && owner.state.dictating && owner.state.needsAttention && owner.state.detail.contains("That text is missing."))
        owner.commands.cancel();owner.audioQueue=[];try? FileManager.default.removeItem(at:spoken)
        print("Session tests passed: recovery, cancellation, continuous voice, auto-close, strip visibility, cursor easing, arrival gating, and fade cancellation.")
    }
}
