import SwiftUI

// Keep everyday wording separate from the full diagnostic report.
enum PilotCopy {
    static func issue(_ detail:String) -> String {
        let text=detail.lowercased()
        if text.contains("file already exists") { return "Choose a different filename." }
        if text.contains("appears more than once") { return "Say a longer, unique phrase." }
        if text.contains("nothing was undone") { return "Text changed. Say select [words]." }
        if text.contains("destination folder does not exist") { return "Choose an existing folder." }
        if text.contains("speech recognition took too long") { return "Speech stalled. Please try again." }
        if text.contains("choose the text area") || text.contains("open a document first") { return "Open a document to dictate." }
        if text.contains("permission") || text.contains("accessibility") || text.contains("screen capture") { return "Check access in Settings" }
        if text.contains("too long") || text.contains("timeout") { return "Slow connection. Please try again." }
        if text.contains("focused app changed") || text.contains("window moved") { return "The window changed. Try again." }
        if text.contains("controls are unavailable") { return "This window needs your help." }
        if text.contains("response space") || text.contains("step limit") { return "Please split this into smaller requests." }
        if text.contains("low confidence") || text.contains("supported next action") { return "Please try a simpler instruction." }
        if text.contains("api key") || text.contains("401") { return "Check your connection in Setup" }
        if text.contains("download") || text.contains("model") && text.contains("missing") { return "Finish setup to get started" }
        return "I got stuck. Tap for details."
    }
    static func hasConfiguredKey(_ key:String,in file:String) -> Bool {
        file.split(separator:"\n").contains { line in
            let line=line.trimmingCharacters(in:.whitespaces)
            let clean=line.hasPrefix("export ") ? String(line.dropFirst(7)) : line
            let parts=clean.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
            guard parts.count==2,parts[0].trimmingCharacters(in:.whitespaces)==key else { return false }
            return !parts[1].trimmingCharacters(in:CharacterSet.whitespaces.union(CharacterSet(charactersIn:"\"'"))).isEmpty
        }
    }
}

enum PilotAppearance: String, CaseIterable {
    case system, dark, light
    var label: String {
        switch self { case .system: return "Follow System"; case .dark: return "Dark"; case .light: return "Light" }
    }
    var native: NSAppearance? {
        switch self { case .system: return nil; case .dark: return NSAppearance(named:.darkAqua); case .light: return NSAppearance(named:.aqua) }
    }
}

enum PilotStyle {
    // Resolve against the window's appearance, including live system changes.
    static func adaptive(_ light:(Double,Double,Double),_ dark:(Double,Double,Double)) -> Color {
        Color(nsColor:NSColor(name:nil) { appearance in
            let rgb=appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed:rgb.0,green:rgb.1,blue:rgb.2,alpha:1)
        })
    }
    static let secondary=adaptive((0.32,0.38,0.40),(0.67,0.73,0.74))
    static let ink=adaptive((0.12,0.19,0.22),(0.90,0.94,0.93))
    static let teal=adaptive((0.07,0.43,0.40),(0.55,0.90,0.77))
    static let accent=adaptive((0.07,0.43,0.40),(0.10,0.44,0.37))
    static let buttonText=adaptive((1,1,1),(0.055,0.085,0.095))
    static let mint=Color(red:0.55,green:0.90,blue:0.77)
    static let buddyInk=Color(red:0.12,green:0.19,blue:0.22)
    static let paper=adaptive((0.97,0.97,0.95),(0.055,0.085,0.095))
    static let card=adaptive((1,1,1),(0.10,0.14,0.15))
    static let hero=adaptive((0.78,0.94,0.86),(0.08,0.23,0.21))
    static let shortcut=adaptive((0.96,0.99,0.97),(0.15,0.30,0.27))
}

struct PilotBuddy: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius:size*0.36).fill(PilotStyle.mint)
            HStack(spacing:size*0.16) {
                Capsule().frame(width:size*0.08,height:size*0.23)
                Capsule().frame(width:size*0.08,height:size*0.23)
            }.foregroundStyle(PilotStyle.buddyInk).rotationEffect(.degrees(-8))
        }.frame(width:size,height:size).accessibilityHidden(true)
    }
}

struct VoiceWave: View {
    var level: CGFloat
    var count = 19
    var body: some View {
        HStack(spacing:3) {
            ForEach(0..<count,id:\.self) { i in
                Capsule().fill(LinearGradient(colors:[PilotStyle.mint,.white.opacity(0.92)],startPoint:.bottom,endPoint:.top))
                    .frame(width:3,height:3+max(0,min(1,level))*CGFloat(8+(i*17)%20))
            }
        }.frame(height:28).animation(.easeOut(duration:0.12),value:level).accessibilityHidden(true)
    }
}

struct PilotView: View {
    @ObservedObject var state: PilotState
    var body: some View {
        HStack(spacing:4) {
            PilotBuddy(size:24).padding(.leading,4)
            TimelineView(.periodic(from:.now,by:0.1)) { context in
                Button { state.activity?() } label: {
                    HStack(spacing:7) {
                        if state.recording && context.date.timeIntervalSince(state.lastSpeech)<0.9 {
                            VoiceWave(level:state.level,count:22).frame(maxWidth:.infinity)
                        } else if state.needsAttention {
                            Image(systemName:state.question.isEmpty ? "exclamationmark.bubble" : "questionmark.bubble").foregroundStyle(.orange)
                            Text(state.compactMessage).font(.system(size:11,weight:.medium)).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                        } else {
                            if state.reviewReady { Image(systemName:"pause.fill").foregroundStyle(PilotStyle.mint) }
                            else if state.busy { ProgressView().controlSize(.mini).tint(PilotStyle.mint) }
                            else { Image(systemName:context.date.timeIntervalSince(state.completedAt)<2 ? "checkmark" : "mic.fill").foregroundStyle(PilotStyle.mint).font(.system(size:11)) }
                            Text(context.date.timeIntervalSince(state.completedAt)<2 && !state.busy && !state.dictating && !state.voiceSleeping ? "All done" : state.shortStatus)
                                .font(.system(size:12,weight:.medium)).lineLimit(1)
                            Spacer(minLength:0)
                            if state.queued>0 {
                                Text("+\(state.queued)").font(.system(size:10,weight:.semibold)).foregroundStyle(PilotStyle.mint)
                                    .accessibilityLabel("\(state.queued) requests waiting")
                            } else if state.recording { VoiceWave(level:state.level,count:5) }
                        }
                    }.frame(maxWidth:.infinity).frame(height:36).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.white)
                    .accessibilityLabel(state.needsAttention ? state.compactMessage : state.shortStatus)
                    .accessibilityValue(state.recording ? "Microphone active" : "Microphone off")
                    .help("Open conversation · Drag to move · \(state.shortcutLabel) to close")
                    .highPriorityGesture(DragGesture(minimumDistance:4).onChanged { _ in state.drag?() }.onEnded { _ in state.endDrag?() })
            }
            if state.busy || !state.question.isEmpty {
                Button { state.cancelTask?() } label: { Image(systemName:"stop.fill").frame(width:28,height:36) }
                    .buttonStyle(.plain).help("Cancel task · Keep listening").accessibilityLabel("Cancel task and keep listening")
            } else {
                Button { state.settings?() } label: { Image(systemName:"gearshape").frame(width:28,height:36) }
                    .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
            }
            Button { state.stop?() } label: { Image(systemName:"xmark").frame(width:28,height:36) }
                .buttonStyle(.plain).help("Stop and close").accessibilityLabel("Stop and close")
        }.font(.system(size:11,weight:.medium)).foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal,6).frame(width:280,height:44)
            .background(Color(red:0.055,green:0.085,blue:0.095),in:RoundedRectangle(cornerRadius:17))
            .overlay(RoundedRectangle(cornerRadius:17).strokeBorder(.white.opacity(0.16)))
            .preferredColorScheme(.dark)
            .contextMenu {
                Button("Conversation") { state.activity?() }
                Button("Settings") { state.settings?() }
                Button("Move below the notch") { state.resetPosition?() }
            }
    }
}

struct PilotCard<Content:View>: View {
    let title:String
    let subtitle:String
    @ViewBuilder var content:Content
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            VStack(alignment:.leading,spacing:4) {
                Text(title).font(.system(size:17,weight:.semibold))
                if !subtitle.isEmpty { Text(subtitle).font(.system(size:13)).foregroundStyle(PilotStyle.secondary).fixedSize(horizontal:false,vertical:true) }
            }
            content
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            .background(PilotStyle.card,in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).strokeBorder(PilotStyle.ink.opacity(0.07)))
    }
}

struct ActivityView: View {
    @ObservedObject var state:PilotState
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:12) {
                PilotBuddy()
                VStack(alignment:.leading,spacing:3) {
                    Text("NotchPilot").font(.system(size:20,weight:.semibold,design:.rounded))
                    Text(state.shortStatus).font(.system(size:13)).foregroundStyle(PilotStyle.secondary)
                }
                Spacer()
                Button { state.settings?() } label: { Image(systemName:"gearshape").padding(8) }.buttonStyle(.plain).help("Settings")
            }
            if state.command.isEmpty && state.question.isEmpty {
                Text("What would you like to do?").font(.system(size:25,weight:.medium,design:.rounded))
                Text("Say it naturally, or type it below. Start with one simple task.").font(.system(size:14)).foregroundStyle(PilotStyle.secondary)
                HStack {
                    example("Open Finder")
                    example("Open Safari")
                }
            }
            if state.reviewReady {
                HStack {
                    Label("Paused · Say “resume task”",systemImage:"pause.circle").font(.system(size:13))
                    Spacer()
                    Button("Resume task") { state.resumeWork?() }.buttonStyle(.borderedProminent).foregroundStyle(PilotStyle.buttonText)
                }
            } else if state.busy { HStack { ProgressView().controlSize(.small);Text(state.phase == "Understanding locally" ? "Understanding your request…" : "Working on your request…") }.font(.system(size:14)) }
            if !state.question.isEmpty {
                Text(state.question).font(.system(size:17,weight:.semibold)).fixedSize(horizontal:false,vertical:true)
                Text("You can answer out loud.").font(.system(size:13)).foregroundStyle(PilotStyle.secondary)
                TextField("Or type your answer",text:$state.answer).textFieldStyle(.roundedBorder).onSubmit { state.reply?() }
                Button("Continue") { state.reply?() }.buttonStyle(.borderedProminent).foregroundStyle(PilotStyle.buttonText).disabled(state.answer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            } else if state.busy {
                VStack(alignment:.leading,spacing:8) {
                    Text("CURRENT REQUEST").font(.system(size:10,weight:.semibold)).foregroundStyle(PilotStyle.secondary)
                    Text(state.command).font(.system(size:16)).lineLimit(3).textSelection(.enabled)
                    HStack {
                        TextField("What should I do next?",text:$state.requestDraft).textFieldStyle(.roundedBorder)
                            .onSubmit { state.addFollowUp?() }
                        Button("Add next") { state.addFollowUp?() }
                            .disabled(state.requestDraft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                if !state.command.isEmpty {
                    Text("Last request: \(state.command)").font(.system(size:12)).foregroundStyle(PilotStyle.secondary).lineLimit(2)
                }
                TextField("For example, open Finder",text:$state.requestDraft,axis:.vertical)
                    .lineLimit(2...4).textFieldStyle(.plain).font(.system(size:16))
                    .padding(16).background(PilotStyle.card,in:RoundedRectangle(cornerRadius:14))
                    .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(PilotStyle.ink.opacity(0.12)))
                    .disabled(state.busy).onSubmit { state.run?() }
            }
            if state.needsAttention && state.question.isEmpty {
                Label(state.friendlyIssue,systemImage:"exclamationmark.bubble").font(.system(size:14,weight:.medium))
                Text("You can give me another instruction. Nothing else is queued.").font(.system(size:13)).foregroundStyle(PilotStyle.secondary)
            } else if !state.busy && !state.detail.isEmpty && !state.command.isEmpty {
                Text(state.detail).font(.system(size:13)).foregroundStyle(PilotStyle.secondary).lineLimit(4)
            }
            if state.queued>0 {
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        Label("Up next · \(state.queued)",systemImage:"text.line.first.and.arrowtriangle.forward")
                        Spacer()
                        Button("Clear waiting requests") { state.clearQueue?() }.buttonStyle(.link)
                    }.font(.system(size:12))
                    ScrollView {
                        VStack(alignment:.leading,spacing:6) {
                            ForEach(Array(state.waitingRequests.enumerated()),id:\.offset) { index,request in
                                Text("\(index+1). \(request)").font(.system(size:13)).frame(maxWidth:.infinity,alignment:.leading)
                            }
                        }
                    }.frame(height:CGFloat(min(state.queued,3))*24)
                }
            }
            HStack {
                Label(state.recording ? "Microphone on" : "Microphone off",systemImage:state.recording ? "mic.fill" : "mic.slash").font(.system(size:12)).foregroundStyle(PilotStyle.secondary)
                Spacer()
                if state.busy || !state.question.isEmpty { Button("Cancel task") { state.cancelTask?() } }
                if state.recording || state.busy { Button("Close") { state.stop?() }.keyboardShortcut(.cancelAction) }
                else { Button("Start talking") { state.beginVoice?() } }
                if state.question.isEmpty && !state.busy {
                    Button("Do this") { state.run?() }.buttonStyle(.borderedProminent).foregroundStyle(PilotStyle.buttonText).keyboardShortcut(.defaultAction)
                        .disabled(state.busy || state.requestDraft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
            }.controlSize(.large)
            DisclosureGroup("What can I say?",isExpanded:$state.showHelp) {
                VStack(alignment:.leading,spacing:7) {
                    ForEach(VoiceHelp.sections,id:\.0) { section in
                        HStack(alignment:.firstTextBaseline,spacing:10) {
                            Text(section.0).fontWeight(.semibold).frame(width:88,alignment:.leading)
                            Text(section.1.joined(separator:" · ")).frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }
                }.font(.system(size:12)).padding(.top,6)
            }.font(.system(size:12)).foregroundStyle(PilotStyle.secondary)
            DisclosureGroup("Details",isExpanded:$state.activityDetails) {
                ScrollView {
                    VStack(alignment:.leading,spacing:8) {
                        Text(state.detail).textSelection(.enabled)
                        if !state.interpreted.isEmpty { Text("Understood: \(state.interpreted)") }
                        Text("Step \(state.step) · $\(state.cost,specifier:"%.4f")")
                    }.font(.system(size:12)).frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:130)
            }.font(.system(size:12)).foregroundStyle(PilotStyle.secondary)
            Text("\(state.shortcutLabel) opens or closes voice. \(state.pauseHint) Say “start dictating” to write continuously, “command mode” for app tasks, or “what can I say” for help.")
                .font(.system(size:12)).foregroundStyle(PilotStyle.secondary)
        }.padding(26).frame(width:460).background(PilotStyle.paper).foregroundStyle(PilotStyle.ink).tint(PilotStyle.teal)
    }
    func example(_ text:String) -> some View { Button(text) { state.requestDraft=text }.buttonStyle(.bordered).controlSize(.large) }
}

struct PreferencesView: View {
    @ObservedObject var state:PilotState
    @ObservedObject var draft:PreferencesDraft
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                PilotBuddy(size:42)
                VStack(alignment:.leading,spacing:3) {
                    Text("NotchPilot").font(.system(size:23,weight:.semibold,design:.rounded))
                    Text("A little help, right here.").font(.system(size:13)).foregroundStyle(PilotStyle.secondary)
                }
                Spacer()
                Button("Conversation") { state.activity?() }.controlSize(.large)
            }.padding(24)
            if state.reviewReady {
                HStack {
                    Text("Paused. Say “resume task” to continue.")
                    Spacer()
                    Button("Resume task") { state.resumeWork?() }.buttonStyle(.borderedProminent).foregroundStyle(PilotStyle.buttonText)
                }.font(.system(size:13)).padding(.horizontal,24).padding(.bottom,12)
            }
            Picker("Settings section",selection:$state.settingsPage) {
                Text("Everyday").tag("Everyday");Text("Setup").tag("Setup");Text("Advanced").tag("Advanced")
            }.pickerStyle(.segmented).tint(PilotStyle.accent).labelsHidden().padding(.horizontal,24).padding(.bottom,16)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    if state.settingsPage == "Everyday" { everyday }
                    else if state.settingsPage == "Setup" { setup }
                    else { advanced }
                }.padding(.horizontal,24).padding(.bottom,24)
            }
        }.background(PilotStyle.paper).foregroundStyle(PilotStyle.ink).tint(PilotStyle.teal)
    }
    var everyday: some View {
        VStack(spacing:16) {
            VStack(alignment:.leading,spacing:18) {
                Text("Just say the word.").font(.system(size:32,weight:.medium,design:.rounded))
                Text("Open NotchPilot. Say what you need.\n\(state.pauseHint)").font(.system(size:15)).lineSpacing(4)
                HStack {
                    Text(state.shortcutLabel).font(.system(size:19,weight:.semibold,design:.rounded)).padding(.horizontal,14).padding(.vertical,9).background(PilotStyle.shortcut,in:RoundedRectangle(cornerRadius:10))
                    Text("Press to talk.\nPress again to close.").font(.system(size:13)).foregroundStyle(PilotStyle.ink.opacity(0.8))
                    Spacer()
                    Button(state.recording ? "Back to listening" : "Start talking") { state.beginVoice?() }.buttonStyle(.borderedProminent).foregroundStyle(PilotStyle.buttonText).controlSize(.large)
                }
                Text("\(state.shortcutWords). Say “cancel that” to cancel a task and keep listening. Say “stop” or press Escape to close.").font(.system(size:12))
            }.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(PilotStyle.hero,in:RoundedRectangle(cornerRadius:20))
            PilotCard(title:"Start with something simple",subtitle:"Say one of these, or click to put it in the conversation.") {
                HStack {
                    Button("Open Finder") { state.example?("Open Finder") }
                    Button("Open Safari") { state.example?("Open Safari") }
                    Button("Visit Wikipedia") { state.example?("Open https://www.wikipedia.org/ in Safari") }
                }.controlSize(.large)
            }
            PilotCard(title:"Make yourself comfortable",subtitle:"") {
                VStack(alignment:.leading,spacing:8) {
                    Label("Appearance",systemImage:"circle.lefthalf.filled").font(.system(size:14,weight:.medium))
                    Picker("Appearance",selection:$state.appearance) {
                        ForEach(PilotAppearance.allCases,id:\.self) { choice in Text(choice.label).tag(choice) }
                    }.pickerStyle(.segmented).tint(PilotStyle.accent).labelsHidden()
                }
                Divider()
                Toggle("Close when the task is finished",isOn:$state.closeWhenDone).toggleStyle(.switch)
                Text(state.closeWhenDone ? "A brief pause gives you time to add another request. Questions and errors stay open." : "The microphone stays on until you close NotchPilot. Keep talking to add more requests.").font(.system(size:13)).foregroundStyle(PilotStyle.secondary)
                Divider()
                VStack(alignment:.leading,spacing:8) {
                    Text("Time to finish speaking").font(.system(size:14,weight:.medium))
                    Picker("Time to finish speaking",selection:$state.speechPause) {
                        Text("Quick · 1 sec").tag(1.0)
                        Text("Relaxed · 2 sec").tag(2.0)
                        Text("Unhurried · 3 sec").tag(3.0)
                    }.pickerStyle(.segmented).tint(PilotStyle.accent).labelsHidden()
                    Text("Choose a longer pause if you like to think between words. Changes apply to your next phrase.")
                        .font(.system(size:13)).foregroundStyle(PilotStyle.secondary)
                    Toggle("Respond sooner to short commands",isOn:$state.earlyCommands).toggleStyle(.switch).padding(.top,4)
                    Text("Commands like “stop”, “scratch that”, and grid numbers run partway through the pause. Longer requests always wait for the full pause.")
                        .font(.system(size:13)).foregroundStyle(PilotStyle.secondary)
                }
                Divider()
                VStack(alignment:.leading,spacing:8) {
                    Text("Words to recognize").font(.system(size:14,weight:.medium))
                    TextField("For example: NotchPilot, Kubernetes, Siobhan",text:$state.vocabularyText).textFieldStyle(.roundedBorder)
                    Text("Names and jargon, separated by commas. Or spell a word aloud, then say “add that to vocabulary.”")
                        .font(.system(size:13)).foregroundStyle(PilotStyle.secondary)
                }
                Divider()
                HStack(alignment:.center,spacing:12) {
                    VStack(alignment:.leading,spacing:4) {
                        Text("Voice check").font(.system(size:14,weight:.medium))
                        Text("Read 12 short phrases to see how well NotchPilot hears you. Results stay on this Mac.")
                            .font(.system(size:13)).foregroundStyle(PilotStyle.secondary)
                    }
                    Spacer()
                    Button("Start") { state.startVoiceCheck?() }.disabled(state.busy)
                }
                Divider()
                Toggle("Ignore quieter voices",isOn:$state.ignoreQuieterVoices).toggleStyle(.switch)
                Text("Experimental. After a few phrases, speech much quieter than yours, like a TV or someone across the room, is ignored. It can’t tell who is speaking.")
                    .font(.system(size:13)).foregroundStyle(PilotStyle.secondary)
                Divider()
                HStack {
                    Label("Your shortcut",systemImage:"keyboard")
                    Spacer();Text(state.shortcutLabel).font(.system(size:14,weight:.semibold))
                    Button(state.capturingShortcut ? "Press keys…" : "Change") { state.recordShortcut?() }.disabled(state.busy)
                }
                if state.capturingShortcut || !state.shortcutDetail.isEmpty { Text(state.capturingShortcut ? "Listening is paused. Press your new shortcut, or Escape to cancel." : state.shortcutDetail).font(.system(size:12)).foregroundStyle(PilotStyle.secondary) }
                Button("Move the strip back below the notch") { state.resetPosition?() }.buttonStyle(.link)
            }
        }
    }
    var setup: some View {
        VStack(spacing:16) {
            PilotCard(title:state.accessReady && state.modelsReady && state.keyConfigured ? "You’re ready to go" : "A little setup. Then just talk.",subtitle:"Three things help NotchPilot hear you, see the right controls, and act.") {
                if state.accessReady && state.modelsReady && state.keyConfigured { Button("Start talking") { state.beginVoice?() }.buttonStyle(.borderedProminent).foregroundStyle(PilotStyle.buttonText).controlSize(.large) }
            }
            PilotCard(title:"1. Allow access on your Mac",subtitle:"macOS asks you to approve these once. Enable NotchPilot in each screen.") {
                access("Hear your voice",system:"mic",allowed:state.microphoneAllowed,pane:"Privacy_Microphone")
                access("Use buttons and controls",system:"cursorarrow",allowed:state.accessibilityAllowed,pane:"Privacy_Accessibility")
                access("Read what’s on screen",system:"rectangle.dashed",allowed:state.screenAllowed,pane:"Privacy_ScreenCapture")
                if state.microphoneAllowed && state.accessibilityAllowed && state.screenAllowed && !state.helperAllowed { Text("Checking the helper. If it stays unavailable, quit and reopen NotchPilot.").font(.system(size:12)).foregroundStyle(PilotStyle.secondary) }
                Button("I’ve enabled them — check again") { state.permission?("check") }.buttonStyle(.link)
            }
            PilotCard(title:"2. Add voice and understanding",subtitle:"Downloaded once. Speech recognition and request interpretation run on this Mac.") {
                HStack {
                    Label(state.modelsReady ? "Ready on this Mac" : "About 1.1 GB for both downloads",systemImage:state.modelsReady ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(PilotStyle.teal)
                    Spacer()
                    if !state.modelsReady { Button("Download essentials") { state.download?("essentials") }.disabled(state.downloading || state.busy || state.recording) }
                }
                if state.downloading { ProgressView(value:state.downloadProgress); Button("Cancel download") { state.cancelDownload?() } }
                if !state.downloadStatus.isEmpty { Text(state.downloadStatus).font(.system(size:12)).foregroundStyle(PilotStyle.secondary) }
            }
            connection
            Text("Voice recordings stay on this Mac. During a task, your request and observed screen text go to the selected service. English and the main display are supported.")
                .font(.system(size:12)).foregroundStyle(PilotStyle.secondary).padding(.horizontal,4)
        }
    }
    var connection: some View {
        PilotCard(title:"3. Connect the online helper",subtitle:"Your service’s API key pays for online decisions. Local voice features have no per-use API charge.") {
            if state.recording { pauseNote }
            if state.engine == "cua" {
                Label("OpenRouter · Cua controller",systemImage:"network").font(.system(size:14,weight:.medium))
            } else {
                Picker("Service",selection:$state.provider) { Text("OpenRouter").tag("openrouter");Text("TypeSafe").tag("typesafe") }
                    .pickerStyle(.segmented).tint(PilotStyle.accent).disabled(state.busy || state.recording).onChange(of:state.provider) { state.refreshConnection?() }
            }
            Label(state.keyConfigured ? "A key is saved on this Mac" : "Add a key to enable online actions",systemImage:state.keyConfigured ? "checkmark.circle.fill" : "key").font(.system(size:13))
            SecureField("Paste your \(state.connectionProvider == "typesafe" ? "TypeSafe" : "OpenRouter") API key",text:state.connectionProvider == "typesafe" ? $draft.typesafeKey : $draft.openrouterKey).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save key") { saveKeys() }.disabled(draft.typesafeKey.isEmpty && draft.openrouterKey.isEmpty)
                Text(draft.message).font(.system(size:12)).foregroundStyle(PilotStyle.secondary)
            }
        }
    }
    var pauseNote: some View {
        HStack {
            Text("Pause listening to change these options.").font(.system(size:12)).foregroundStyle(PilotStyle.secondary)
            Spacer();Button("Pause voice") { state.pauseVoice?() }.disabled(state.busy)
        }
    }
    var advanced: some View {
        VStack(spacing:16) {
            if state.recording { pauseNote }
            PilotCard(title:"Control engine",subtitle:"Cua targets native app windows. Jev remains available for comparison.") {
                Picker("Engine",selection:$state.engine) { Text("Cua").tag("cua");Text("Jev · experimental").tag("jev") }.pickerStyle(.segmented).tint(PilotStyle.accent)
                    .disabled(state.busy || state.recording).onChange(of:state.engine) { state.refreshConnection?() }
                Text("Cua uses GPT-5 mini through OpenRouter to choose actions from native controls. It does not call Jev or enable browser debugging.").font(.system(size:12)).foregroundStyle(PilotStyle.secondary)
            }
            PilotCard(title:"Understanding & writing",subtitle:"These options affect how requests are interpreted and carried out.") {
                Toggle("Understand casual requests",isOn:$state.localInterpreter).disabled(state.busy || state.recording || !state.question.isEmpty)
                Text("Qwen3 1.7B runs locally to resolve wording and context.").font(.system(size:12)).foregroundStyle(PilotStyle.secondary)
                Toggle("Allow online text composition",isOn:$state.writerEnabled).disabled(state.busy || state.recording)
                Text("Uses GPT-5 mini through OpenRouter for text fields. Additional API usage applies.").font(.system(size:12)).foregroundStyle(PilotStyle.secondary)
                Toggle("Preview the next action without doing it",isOn:$state.preview).disabled(state.busy || state.recording)
            }
            PilotCard(title:"Local downloads",subtitle:"Only repair these if a download is missing or damaged.") {
                model("Speech recognition","Whisper base.en · 148 MB",ready:state.whisperInstalled,name:"whisper")
                Divider()
                model("Speech detection","Silero VAD · 0.9 MB",ready:state.vadInstalled,name:"vad")
                Divider()
                model("Request interpretation","Qwen3 1.7B · 984 MB",ready:state.qwenInstalled,name:"qwen")
                if state.downloading { ProgressView(value:state.downloadProgress);Button("Cancel download") { state.cancelDownload?() } }
                Text(state.downloadStatus).font(.system(size:12)).foregroundStyle(PilotStyle.secondary)
            }
            PilotCard(title:"Access details",subtitle:state.permissions) { Button("Recheck access") { state.permission?("check") } }
        }
    }
    func access(_ title:String,system:String,allowed:Bool,pane:String) -> some View {
        HStack {
            Label(title,systemImage:system).font(.system(size:14))
            Spacer()
            if allowed { Label("Ready",systemImage:"checkmark.circle.fill").font(.system(size:12)).foregroundStyle(PilotStyle.teal) }
            else { Button("Allow…") { state.permission?(pane) }.controlSize(.large) }
        }
    }
    func model(_ title:String,_ detail:String,ready:Bool,name:String) -> some View {
        HStack {
            VStack(alignment:.leading,spacing:3) { Text(title).font(.system(size:14,weight:.medium));Text(detail).font(.system(size:12)).foregroundStyle(PilotStyle.secondary) }
            Spacer();Button(ready ? "Verify / repair" : "Download") { state.download?(name) }.disabled(state.downloading || state.busy || state.recording)
        }
    }
    func saveKeys() {
        var success=true
        if !draft.typesafeKey.isEmpty { success=Credentials.save(draft.typesafeKey.trimmingCharacters(in:.whitespacesAndNewlines),account:"TYPESAFE_API_KEY") && success }
        if !draft.openrouterKey.isEmpty { success=Credentials.save(draft.openrouterKey.trimmingCharacters(in:.whitespacesAndNewlines),account:"OPENROUTER_API_KEY") && success }
        draft.message=success ? "Saved securely in Keychain." : "Couldn’t save. Please try again."
        if success { draft.typesafeKey="";draft.openrouterKey="" }
        state.refreshConnection?()
    }
}
