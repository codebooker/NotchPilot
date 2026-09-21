import SwiftUI
import AppKit
import AVFoundation
import Carbon
import ApplicationServices
import Security

#if !SESSION_TESTS
@main
struct NotchPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}
#endif

struct Runtime: Decodable {
    let root: String
    let python: String
    let worker: String
    let whisper: String
    let model: String
    let vad: String
    let vadModel: String
    let planner: String
    let qwen: String
    let downloader: String
    static func load() throws -> Runtime {
        let url = Bundle.main.url(forResource: "runtime", withExtension: "json")!
        return try JSONDecoder().decode(Runtime.self, from: Data(contentsOf: url))
    }
}

final class PilotState: ObservableObject {
    @Published var engine = UserDefaults.standard.string(forKey:"engine") ?? "cua" {
        didSet { UserDefaults.standard.set(engine,forKey:"engine") }
    }
    var connectionProvider: String { engine == "cua" ? "openrouter" : provider }
    @Published var activityDetails = false
    @Published var showHelp = false
    /// Active or finished voice check; nil when none is shown.
    @Published var voiceCheck: VoiceCheck?
    @Published var voiceCheckFile = ""
    var startVoiceCheck: (() -> Void)?
    var voiceCheckControl: ((VoiceCheck.Control) -> Void)?
    @Published var settingsPage = "Everyday"
    @Published var appearance = PilotAppearance(rawValue:UserDefaults.standard.string(forKey:"appearance") ?? "system") ?? .system {
        didSet { UserDefaults.standard.set(appearance.rawValue,forKey:"appearance");changeAppearance?() }
    }
    var changeAppearance: (() -> Void)?
    @Published var microphoneAllowed = false
    @Published var accessibilityAllowed = false
    @Published var screenAllowed = false
    @Published var helperAllowed = false
    @Published var keyConfigured = false
    @Published var completedAt = Date.distantPast
    @Published var phase = "Opening"
    @Published var detail = "Tell your Mac what you want to do."
    @Published var command = ""
    @Published var question = ""
    @Published var answer = ""
    @Published var interpreted = ""
    @Published var qwenInstalled = false
    @Published var whisperInstalled = false
    @Published var vadInstalled = false
    @Published var downloading = false
    @Published var downloadProgress = 0.0
    @Published var downloadStatus = ""
    @Published var capturingShortcut = false
    @Published var shortcutLabel = "⌃⌥Space"
    @Published var shortcutDetail = "Press this shortcut to open the panel and start listening."
    @Published var localInterpreter = UserDefaults.standard.object(forKey:"localInterpreter") as? Bool ?? true {
        didSet { UserDefaults.standard.set(localInterpreter,forKey:"localInterpreter") }
    }
    @Published var dictating = false
    @Published var ignoreQuieterVoices = UserDefaults.standard.bool(forKey:"ignoreQuieterVoices") {
        didSet { UserDefaults.standard.set(ignoreQuieterVoices,forKey:"ignoreQuieterVoices") }
    }
    /// Comma-separated words that Whisper should spell your way, such as names and jargon.
    @Published var vocabularyText = UserDefaults.standard.string(forKey:"vocabulary") ?? "" {
        didSet { UserDefaults.standard.set(vocabularyText,forKey:"vocabulary") }
    }
    var vocabulary: [String] {
        vocabularyText.split(separator:",").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    @discardableResult func addVocabulary(_ word: String) -> Bool {
        let clean=word.trimmingCharacters(in:.whitespacesAndNewlines)
        guard (1...40).contains(clean.count),!clean.contains(","),!clean.contains(where:\.isNewline),
              !vocabulary.contains(where:{ $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return false }
        vocabularyText=(vocabulary+[clean]).joined(separator:", "); return true
    }
    @discardableResult func removeVocabulary(_ word: String) -> Bool {
        let kept=vocabulary.filter { $0.caseInsensitiveCompare(word.trimmingCharacters(in:.whitespacesAndNewlines)) != .orderedSame }
        guard kept.count<vocabulary.count else { return false }
        vocabularyText=kept.joined(separator:", "); return true
    }
    @Published var voiceSleeping = false
    @Published var recording = false
    @Published var closeWhenDone = UserDefaults.standard.object(forKey:"closeWhenDone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(closeWhenDone,forKey:"closeWhenDone") }
    }
    @Published var busy = false
    @Published var reviewing = false
    @Published var reviewReady = false
    var resumeWork: (() -> Void)?
    @Published var preview = false
    @Published var waitingRequests: [String] = []
    var queued: Int { waitingRequests.count }
    @Published var requestDraft = ""
    @Published var speechPause = min(3,max(1,UserDefaults.standard.object(forKey:"speechPause") as? Double ?? 1)) {
        didSet { UserDefaults.standard.set(speechPause,forKey:"speechPause"); changeSpeechPause?(speechPause) }
    }
    var pauseHint: String { "Pause for \(Int(speechPause)) \(speechPause == 1 ? "second" : "seconds") after each request." }
    @Published var permissions = "Checking permissions…"
    @Published var level: CGFloat = 0
    @Published var lastSpeech = Date.distantPast
    @Published var step = 0
    @Published var cost = 0.0
    @Published var provider = UserDefaults.standard.string(forKey: "provider") ?? "openrouter" {
        didSet { UserDefaults.standard.set(provider, forKey: "provider") }
    }
    @Published var writerEnabled = UserDefaults.standard.bool(forKey: "writerEnabled") {
        didSet { UserDefaults.standard.set(writerEnabled, forKey: "writerEnabled") }
    }
    var changeSpeechPause: ((Double) -> Void)?
    var cancelTask: (() -> Void)?
    var clearQueue: (() -> Void)?
    var addFollowUp: (() -> Void)?
    var beginVoice: (() -> Void)?
    var pauseVoice: (() -> Void)?
    var example: ((String) -> Void)?
    var refreshConnection: (() -> Void)?
    var toggle: (() -> Void)?
    var run: (() -> Void)?
    var stop: (() -> Void)?
    var settings: (() -> Void)?
    var permission: ((String) -> Void)?
    var recordShortcut: (() -> Void)?
    var reply: (() -> Void)?
    var download: ((String) -> Void)?
    var cancelDownload: (() -> Void)?
    var activity: (() -> Void)?
    var drag: (() -> Void)?
    var endDrag: (() -> Void)?
    var resetPosition: (() -> Void)?

    var needsAttention: Bool { !question.isEmpty || phase.localizedCaseInsensitiveContains("attention") }
    func showsWaves(at date: Date) -> Bool {
        recording && (!needsAttention || date.timeIntervalSince(lastSpeech)<0.9)
    }
    var shortcutWords: String {
        shortcutLabel.replacingOccurrences(of:"⌃",with:"Control + ").replacingOccurrences(of:"⌥",with:"Option + ")
            .replacingOccurrences(of:"⌘",with:"Command + ").replacingOccurrences(of:"⇧",with:"Shift + ")
    }
    var accessReady: Bool { microphoneAllowed && accessibilityAllowed && screenAllowed && helperAllowed }
    var modelsReady: Bool { whisperInstalled && vadInstalled && (!localInterpreter || qwenInstalled) }
    var shortStatus: String {
        if !question.isEmpty { return "One quick question" }
        if needsAttention { return "Let’s try that again" }
        if reviewing { return reviewReady ? "Paused for you" : "Pausing…" }
        if busy { return phase == "Understanding locally" ? "Thinking…" : "Working…" }
        return recording ? (voiceSleeping ? "Say wake up" : dictating ? "Dictating" : "I’m listening") : "Ready when you are"
    }
    var friendlyIssue: String { PilotCopy.issue(detail) }
    var compactMessage: String {
        if !question.isEmpty { return question }
        if needsAttention { return friendlyIssue }
        if busy { return "Working…" }
        return phase == "Finished" ? "Done" : "Starting microphone…"
    }
}

enum Credentials {
    static let service = "local.notchpilot.credentials"
    static func read(_ account: String) -> String? {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service,kSecAttrAccount as String:account,
            kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,
              let data=result as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    static func save(_ value: String, account: String) -> Bool {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service,kSecAttrAccount as String:account]
        let data = Data(value.utf8)
        let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecItemNotFound {
            var item=query; item[kSecValueData as String]=data
            return SecItemAdd(item as CFDictionary,nil)==errSecSuccess
        }
        return status==errSecSuccess
    }
}

final class PreferencesDraft: ObservableObject {
    @Published var typesafeKey = ""
    @Published var openrouterKey = ""
    @Published var message = "Existing project .env keys work as a fallback."
}

final class FloatingPanel: NSPanel {
    // The voice strip has no text input. A key-capable nonactivating panel can
    // retain keyboard focus even while macOS reports another app as frontmost.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = PilotState()
    var panel: FloatingPanel!
    var cursor: NSWindow!
    var cursorMotion: CursorMotion?
    var statusItem: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var runtime: Runtime?
    var speech: SpeechCapture?
    var transcribing = false
    let whisperSession = WhisperSession()
    let vadSession = VADSession()
    var audioQueue: [URL] = []
    var transcribingURL: URL?
    var voiceGeneration = UUID()
    var audioEpoch = UUID()
    var commands = VoiceCommandQueue()
    var workerSucceeded = false
    let planner = PlannerClient()
    let voiceEditor = VoiceEditor()
    var originalGoal = ""
    var resolvedGoal = ""
    var flightPlan: [String:Any]?
    var dialogue: [[String:String]] = []
    var shortcutCode = UInt32(UserDefaults.standard.object(forKey:"shortcutCode") as? Int ?? kVK_Space)
    var shortcutModifiers = UInt32(UserDefaults.standard.object(forKey:"shortcutModifiers") as? Int ?? (controlKey | optionKey))
    var downloadTask: Process?
    var permissionTask: Process?
    var permissionRequestPending = false
    var helperReady = false
    var helperStatus = "checking"
    var task: Process?
    var input: Pipe?
    var generation = UUID()
    var targetApp: NSRunningApplication?
    var targetWindowID: Int?
    var localMonitor: Any?
    var escapeHotKey: EventHotKeyRef?
    var preferences: NSWindow?
    var activityWindow: NSWindow?
    var pendingReview: String?
    var reviewToken: UUID?
    var panelPositioned = false
    var panelDragOrigin: NSPoint?
    var panelDragMouse: NSPoint?
    var pendingVoiceStart = false
    var startingVoice = false
    var autoCloseGeneration = UUID()
    let preferencesDraft = PreferencesDraft()
    var qaInbox: QAInbox?
    /// Remembered across launches, so "ignore quieter voices" knows your level from the start.
    var levelGate = VoiceLevelGate(levels:UserDefaults.standard.array(forKey:"voiceLevels") as? [Double] ?? [])
    var pointing: Pointing?
    let speechOutput = SpeechOutput()
    var voiceCheckWindow: NSWindow?
    /// When each phrase finished and how loud it was, for voice-check timing.
    var segmentInfo: [URL:(ended:Date,level:Double?)] = [:]
    var readingToken: UUID?
    let pointingOverlay = PointingOverlay()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index=CommandLine.arguments.firstIndex(of:"--probe-cua"),CommandLine.arguments.count>index+1 {
            NSApp.setActivationPolicy(.prohibited)
            let path=CommandLine.arguments[index+1]
            DispatchQueue.global().async {
                do {
                    let runtime=try Runtime.load();let process=Process()
                    process.executableURL=URL(fileURLWithPath:runtime.python)
                    process.arguments=["-B",URL(fileURLWithPath:runtime.worker).deletingLastPathComponent().appendingPathComponent("cua_agent.py").path,"--probe",path]
                    FileManager.default.createFile(atPath:path+".log",contents:nil)
                    process.standardError=FileHandle(forWritingAtPath:path+".log")
                    try process.run();process.waitUntilExit();exit(process.terminationStatus)
                } catch { exit(1) }
            }
            return
        }
        NSApp.setActivationPolicy(.accessory)
        runtime = try? Runtime.load()
        refreshModels()
        if state.whisperInstalled && state.vadInstalled,let runtime {
            try? whisperSession.prepare(runtime); try? vadSession.prepare(runtime)
        }
        let host = NSHostingView(rootView: PilotView(state: state))
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground=true
        cursor = CursorOverlay.makeWindow()
        cursorMotion=CursorMotion(window:cursor)
        state.beginVoice = { [weak self] in
            guard let self else { return }
            if self.state.reviewing { self.resumeReviewedWork();return }
            self.preferences?.orderOut(nil); self.activityWindow?.orderOut(nil)
            if self.state.recording { self.showPanel(key:false) } else { self.openVoice() }
        }
        state.changeAppearance = { [weak self] in self?.applyAppearance() }
        state.startVoiceCheck = { [weak self] in self?.startVoiceCheck() }
        state.voiceCheckControl = { [weak self] control in self?.controlVoiceCheck(control) }
        state.resumeWork = { [weak self] in self?.resumeReviewedWork() }
        state.changeSpeechPause = { [weak self] seconds in self?.speech?.setPause(seconds) }
        state.cancelTask = { [weak self] in self?.cancelCurrentTask() }
        state.clearQueue = { [weak self] in self?.clearWaitingRequests() }
        state.addFollowUp = { [weak self] in self?.runCommand() }
        state.pauseVoice = { [weak self] in self?.stop(close:false) }
        state.example = { [weak self] text in self?.state.requestDraft=text;self?.showActivity() }
        state.refreshConnection = { [weak self] in self?.refreshConnection() }
        state.toggle = { [weak self] in self?.hotkey() }
        state.run = { [weak self] in self?.runCommand() }
        state.reply = { [weak self] in self?.submitAnswer(self?.state.answer ?? "") }
        state.recordShortcut = { [weak self] in
            if self?.state.recording == true { self?.stop(close:false) }
            self?.state.capturingShortcut=true
            self?.state.shortcutDetail="Press a key with Option, Control, or Command. Escape cancels."
            self?.preferences?.makeFirstResponder(nil)
        }
        state.stop = { [weak self] in self?.stop(close: true) }
        state.settings = { [weak self] in self?.showSettings() }
        state.activity = { [weak self] in self?.showActivity() }
        state.drag = { [weak self] in self?.dragPanel() }
        state.endDrag = { [weak self] in self?.panelDragOrigin=nil; self?.panelDragMouse=nil }
        state.resetPosition = { [weak self] in self?.panelPositioned=false; self?.showPanel(key:false) }
        state.permission = { [weak self] pane in self?.requestPermission(pane) }
        state.download = { [weak self] name in self?.downloadModel(name) }
        state.cancelDownload = { [weak self] in self?.cancelModelDownload() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "NotchPilot")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open NotchPilot", action: #selector(showFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Commands and activity…", action: #selector(showActivity), keyEquivalent: "")
        menu.addItem(withTitle: "Permissions and setup", action: #selector(showSettings), keyEquivalent: "")
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit NotchPilot", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }; statusItem.menu = menu
        registerHotkey()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.state.capturingShortcut == true { self?.captureShortcut(event); return nil }
            if event.keyCode == 53 { self?.stop(close: true); return nil }; return event
        }
        if let inbox=QAInbox(arguments:CommandLine.arguments) {
            // Live tests submit typed instructions. The microphone stays off unless --qa-listen is also given.
            qaInbox=inbox;showPanel(key:false)
            inbox.start(submit:{ [weak self] in self?.acceptInstruction($0) },status:{ [weak self] in self?.qaStatus() ?? [:] })
            if CommandLine.arguments.contains("--qa-listen") { DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [weak self] in self?.openVoice() } }
        } else if CommandLine.arguments.contains("--render-settings") {
            showSettings()
            state.settingsPage=CommandLine.arguments.contains("--preview-setup") ? "Setup" : "Everyday"
            DispatchQueue.main.asyncAfter(deadline: .now()+0.7) { [weak self] in self?.renderPreview(settings:true) }
        } else if CommandLine.arguments.contains("--render-voice-check") {
            var sample=VoiceCheck()
            sample.record(heard:"Open Safari.",seconds:0.7,level:-21)
            sample.record(heard:"What can I say?",seconds:0.6,level:-22)
            sample.record(heard:"Show number.",seconds:0.8,level:-20)
            if CommandLine.arguments.contains("--preview-finished") {
                while let phrase=sample.current { sample.record(heard:phrase.text,seconds:0.7,level:-21) }
            }
            state.voiceCheck=sample;state.recording=true;presentVoiceCheck()
            DispatchQueue.main.asyncAfter(deadline: .now()+0.7) { [weak self] in self?.renderPreview(voiceCheck:true) }
        } else if CommandLine.arguments.contains("--render-activity") {
            state.showHelp=true;presentActivity()
            DispatchQueue.main.asyncAfter(deadline: .now()+0.7) { [weak self] in self?.renderPreview(activity:true) }
        } else if CommandLine.arguments.contains("--render-preview") {
            if CommandLine.arguments.contains("--preview-waves") { state.recording=true;state.level=0.65 }
            if CommandLine.arguments.contains("--preview-question") { state.question="Which Tom did you mean?";state.phase="Needs attention" }
            showPanel(key: false)
            DispatchQueue.main.asyncAfter(deadline: .now()+0.7) { [weak self] in self?.renderPreview() }
        } else {
            showPanel(key: false)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [weak self] in self?.openVoice() }
        }
    }

    func registerHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier=EventHotKeyID()
            guard GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,
                                    MemoryLayout<EventHotKeyID>.size,nil,&identifier)==noErr,
                  identifier.signature==0x4E50494C, [UInt32(1),UInt32(2)].contains(identifier.id)
            else { return OSStatus(eventNotHandledErr) }
            let isEscape=identifier.id==2
            let owner = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                if owner.state.capturingShortcut { owner.state.capturingShortcut=false; owner.state.shortcutDetail="Shortcut unchanged." }
                else if isEscape { owner.stop(close:true) }
                else { owner.hotkey() }
            }; return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        state.shortcutLabel=UserDefaults.standard.string(forKey:"shortcutLabel") ?? "⌃⌥Space"
        if !UserDefaults.standard.bool(forKey:"shortcutConflictMigration") {
            if shortcutCode == UInt32(kVK_Space) && shortcutModifiers == UInt32(optionKey) {
                shortcutModifiers = UInt32(controlKey | optionKey); state.shortcutLabel="⌃⌥Space"
            }
            UserDefaults.standard.set(true,forKey:"shortcutConflictMigration")
        }
        _=installShortcut(shortcutCode,modifiers:shortcutModifiers,label:state.shortcutLabel)
    }

    // Register only the stop key while the strip is open. A global NSEvent keyDown
    // monitor observes every user's keystroke even when no automation is running.
    // Ordinary typing should never travel through a NotchPilot global listener.
    func setEscapeShortcut(active: Bool) {
        if active, escapeHotKey==nil {
            RegisterEventHotKey(UInt32(kVK_Escape),0,EventHotKeyID(signature:0x4E50494C,id:2),
                                GetApplicationEventTarget(),0,&escapeHotKey)
        } else if !active, let key=escapeHotKey {
            UnregisterEventHotKey(key); escapeHotKey=nil
        }
    }
    @discardableResult func installShortcut(_ code: UInt32, modifiers: UInt32, label: String) -> Bool {
        if hotKey != nil && code==shortcutCode && modifiers==shortcutModifiers { return true }
        var candidate: EventHotKeyRef?
        let result=RegisterEventHotKey(code,modifiers,EventHotKeyID(signature:0x4E50494C,id:1),GetApplicationEventTarget(),0,&candidate)
        guard result==noErr else { state.shortcutDetail="That shortcut is unavailable. Choose another combination."; return false }
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey=candidate
        shortcutCode=code; shortcutModifiers=modifiers; state.shortcutLabel=label
        UserDefaults.standard.set(Int(code),forKey:"shortcutCode"); UserDefaults.standard.set(Int(modifiers),forKey:"shortcutModifiers")
        UserDefaults.standard.set(label,forKey:"shortcutLabel")
        state.shortcutDetail="\(label) opens the panel and starts listening; press again to stop."
        return true
    }
    func captureShortcut(_ event: NSEvent) {
        if event.keyCode==53 { state.capturingShortcut=false; state.shortcutDetail="Shortcut unchanged."; return }
        let flags=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command,.control,.option]).isEmpty else { state.shortcutDetail="Include Option, Control, or Command."; return }
        var modifiers: UInt32=0; var label=""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        label += event.keyCode==UInt16(kVK_Space) ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
        state.capturingShortcut=false
        _=installShortcut(UInt32(event.keyCode),modifiers:modifiers,label:label)
    }

    func showPanel(key: Bool) {
        guard let screen = NSScreen.screens.first(where:{$0.safeAreaInsets.top>0}) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        if !panelPositioned {
            let inset=max(screen.safeAreaInsets.top,screen.frame.maxY-screen.visibleFrame.maxY)
            panel.setFrame(NSRect(x:screen.frame.midX-140,y:screen.frame.maxY-inset-48,width:280,height:44),display:true)
            panelPositioned=true
        }
        if key { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        setEscapeShortcut(active:true)
    }

    func dragPanel() {
        let mouse=NSEvent.mouseLocation
        if panelDragOrigin==nil { panelDragOrigin=panel.frame.origin;panelDragMouse=mouse }
        guard let origin=panelDragOrigin,let start=panelDragMouse else { return }
        var next=NSPoint(x:origin.x+mouse.x-start.x,y:origin.y+mouse.y-start.y)
        if let screen=NSScreen.screens.first(where:{$0.frame.contains(mouse)}) {
            next.x=min(max(next.x,screen.visibleFrame.minX),screen.visibleFrame.maxX-panel.frame.width)
            next.y=min(max(next.y,screen.visibleFrame.minY),screen.visibleFrame.maxY-panel.frame.height)
        }
        panel.setFrameOrigin(next);panelPositioned=true
    }

    @objc func showFromMenu() {
        if state.recording || state.busy { showPanel(key:false) }
        else { openVoice() }
    }
    func rememberTarget() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            targetApp=app
            targetWindowID=HostKeyboard.frontWindow(pid:app.processIdentifier,bundle:app.bundleIdentifier)
        }
    }
    func hotkey() {
        if state.busy || state.recording || startingVoice || pendingVoiceStart || transcribing { stop(close: true); return }
        openVoice()
    }
    func openVoice() {
        guard !state.recording, !startingVoice, !state.busy else { return }
        rememberTarget(); showPanel(key:false)
        guard desktopReady else {
            pendingVoiceStart=true;state.phase="Preparing";state.detail="Finish permission setup in Settings."
            setupPermissions();return
        }
        pendingVoiceStart=false
        refreshModels()
        guard state.whisperInstalled && state.vadInstalled && (!state.localInterpreter || state.qwenInstalled) else {
            state.phase="Needs attention";state.detail="Download the missing local models in Settings."; showSettings(); return
        }
        if state.question.isEmpty { commands.cancel() }
        startListening()
    }

    var desktopReady: Bool { AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() && helperReady }

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for:.audio) == .authorized
        state.microphoneAllowed=mic;state.accessibilityAllowed=AXIsProcessTrusted()
        state.screenAllowed=CGPreflightScreenCaptureAccess();state.helperAllowed=helperReady
        state.permissions = "Microphone: \(mic ? "allowed" : "needed") · Accessibility: \(AXIsProcessTrusted() ? "allowed" : "needed") · Screen Recording: \(CGPreflightScreenCaptureAccess() ? "allowed" : "needed")\nHelper: \(helperStatus)"
    }
    func setupPermissions() {
        refreshPermissions()
        if !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() || AVCaptureDevice.authorizationStatus(for:.audio) != .authorized {
            showSettings()
            requestPermission("all")
        } else { checkHelperPermissions(request: true) }
    }
    func requestPermission(_ pane: String) {
        if pane == "all" || pane == "Privacy_Accessibility" {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if (pane == "all" || pane == "Privacy_ScreenCapture") && !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        if pane == "all" || pane == "Privacy_Microphone" {
            AVCaptureDevice.requestAccess(for:.audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshPermissions() }
            }
        }
        if pane.hasPrefix("Privacy_"), let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?"+pane) {
            NSWorkspace.shared.open(url)
        }
        refreshPermissions(); checkHelperPermissions(request:pane != "check")
    }
    func checkHelperPermissions(request: Bool) {
        guard let runtime else { return }
        if permissionTask != nil { permissionRequestPending = permissionRequestPending || request; return }
        let process=Process(); let output=Pipe()
        process.executableURL=URL(fileURLWithPath:runtime.python)
        process.arguments=["-B",runtime.worker,"--root",runtime.root,"--permissions"] + (request ? ["--request-permissions"] : [])
        process.standardOutput=output; process.standardError=FileHandle.nullDevice
        permissionTask=process
        do { try process.run() } catch { permissionTask=nil; helperReady=false; helperStatus="could not start"; refreshPermissions(); return }
        DispatchQueue.global().async { [weak self] in
            let data=output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let result=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            DispatchQueue.main.async {
                guard let self else { return }
                self.permissionTask=nil
                self.helperReady=result?["accessibility"] as? Bool == true && result?["screen"] as? Bool == true
                if result == nil { self.helperStatus="permission check failed" }
                else if self.helperReady { self.helperStatus="ready" }
                else {
                    var missing: [String]=[]
                    if result?["accessibility"] as? Bool != true { missing.append("Accessibility") }
                    if result?["screen"] as? Bool != true { missing.append("Screen Recording") }
                    self.helperStatus="needs " + missing.joined(separator:" and ") + ". If already enabled, quit and reopen NotchPilot."
                }
                self.refreshPermissions()
                if self.helperReady && self.pendingVoiceStart { self.openVoice() }
                if self.permissionRequestPending {
                    self.permissionRequestPending=false
                    if !self.helperReady { self.checkHelperPermissions(request:true) }
                }
            }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !CommandLine.arguments.contains(where:{$0.hasPrefix("--render-")}) else { return }
        refreshPermissions(); checkHelperPermissions(request:false)
    }

    func startListening() {
        guard !startingVoice, !state.recording, let runtime else { return }
        startingVoice=true
        let token=UUID(); voiceGeneration=token
        AVCaptureDevice.requestAccess(for:.audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.voiceGeneration == token else { return }
                self.startingVoice=false
                guard granted else { self.fail("Enable Microphone access in Settings."); return }
                let capture=SpeechCapture()
                capture.pauseDuration=self.state.speechPause
                capture.segmentEpoch = self.audioEpoch
                capture.onSegment = { [weak self] url, epoch, level in
                    DispatchQueue.main.async {
                        guard let self, self.voiceGeneration == token, self.audioEpoch == epoch else { try? FileManager.default.removeItem(at:url); return }
                        self.segmentInfo[url]=(Date(),level)
                        let known=self.levelGate.levels.count
                        if let level, !self.levelGate.accepts(level), self.state.ignoreQuieterVoices, self.state.voiceCheck?.finished != false {
                            try? FileManager.default.removeItem(at:url)
                            self.state.detail="Ignored a quieter voice. Speak as you usually do, or turn this off in Settings."; return
                        }
                        if self.levelGate.levels.count != known || known==20 { UserDefaults.standard.set(self.levelGate.levels,forKey:"voiceLevels") }
                        guard self.audioQueue.count < 8 else { try? FileManager.default.removeItem(at:url); self.fail("Speech queue is full. Please let the current instructions finish."); return }
                        self.audioQueue.append(url); self.transcribeNext()
                    }
                }
                capture.onLevel = { [weak self] level in
                    DispatchQueue.main.async {
                        guard let self, self.voiceGeneration == token else { return }
                        self.state.level=level
                    }
                }
                capture.onVoiceActivity = { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, self.voiceGeneration == token else { return }
                        self.state.lastSpeech=Date()
                    }
                }
                capture.onError = { [weak self] message in
                    DispatchQueue.main.async { guard let self, self.voiceGeneration == token else { return }; self.fail(message) }
                }
                do {
                    try self.vadSession.prepare(runtime)
                    self.speech=capture; try capture.start(vad:self.vadSession); self.state.recording=true
                    self.state.phase=self.state.question.isEmpty ? "Listening" : "Listening for your answer"; self.state.detail="Pause after speaking to submit. \(self.state.shortcutLabel) stops the session."
                } catch { self.fail("Microphone capture could not start. Check the input device and permissions.") }
            }
        }
    }

    func transcribeNext() {
        guard !transcribing, !audioQueue.isEmpty, let runtime else { return }
        let url=audioQueue.removeFirst(); transcribingURL=url
        let token=voiceGeneration; let epoch=audioEpoch
        transcribing=true
        if !state.busy { state.phase="Listening · transcribing" }
        // A voice check decodes each phrase the way real use would: commands with the command
        // prompt, dictation sentences with the previous sentence as context.
        let checking=state.voiceCheck.flatMap { $0.finished ? nil : $0.current }
        let prompt=checking.map { SpeechText.prompt(dictation:$0.dictation,vocabulary:state.vocabulary,context:state.voiceCheck?.previousDictation ?? "") } ?? speechPrompt()
        whisperSession.transcribe(runtime:runtime,url:url,dictation:checking?.dictation ?? state.dictating,prompt:prompt) { [weak self] result in
            try? FileManager.default.removeItem(at:url)
            let info=self?.segmentInfo.removeValue(forKey:url)
            guard let self,self.voiceGeneration==token,self.audioEpoch==epoch else { return }
            self.transcribing=false;self.transcribingURL=nil
            switch result {
            case .failure(let error): self.fail(error.localizedDescription);return
            case .success(let text):
                if self.state.voiceCheck?.finished == false {
                    if !SpeechText.isNonSpeech(text) {
                        self.recordVoiceCheck(SpeechText.applyVocabulary(text,self.state.vocabulary),seconds:info.map { Date().timeIntervalSince($0.ended) },level:info?.level ?? nil)
                    }
                } else if !SpeechText.isNonSpeech(text,dictation:self.state.dictating) { self.acceptInstruction(SpeechText.applyVocabulary(text,self.state.vocabulary)) }
            }
            self.transcribeNext()
        }
    }
    /// Vocabulary for every phrase; while dictating, also the text before the caret plus phrases
    /// still waiting to be typed, so a sentence split by a pause keeps its casing.
    func speechPrompt() -> String {
        var context=""
        if state.dictating,let bound=voiceEditor.target {
            let queued=([commands.active].compactMap { $0 }+commands.pending).filter { VoiceEditCommand.parse($0)==nil }
            context=([voiceEditor.textBeforeCaret(pid:bound.pid,window:bound.window) ?? ""]+queued).joined(separator:" ")
        }
        return SpeechText.prompt(dictation:state.dictating,vocabulary:state.vocabulary,context:context)
    }
    @discardableResult func handleSessionInstruction(_ text: String) -> Bool {
        let phrase=VoiceCommandQueue.normalized(text)
        if ["go to sleep","pause listening"].contains(phrase) {
            cancelCurrentTask();state.voiceSleeping=true;state.detail="Paused. Say wake up or resume listening.";return true
        }
        if ["voice check","start voice check","start a voice check","check my voice"].contains(phrase) { startVoiceCheck();return true }
        if ["wake up","resume listening"].contains(phrase) {
            state.voiceSleeping=false;state.phase="Listening";state.detail="I’m listening again.";return true
        }
        if state.voiceSleeping && !VoiceCommandQueue.isStop(text) { return true }
        if VoiceCommandQueue.isStop(text) { stop(close:true); return true }
        if VoiceCommandQueue.isCancelTask(text) { cancelCurrentTask(); return true }
        if state.reviewing && VoiceCommandQueue.isResumeTask(text) { resumeReviewedWork(); return true }
        if VoiceCommandQueue.isClearQueue(text) { clearWaitingRequests(); return true }
        return false
    }
    func acceptInstruction(_ text: String) {
        if state.voiceCheck?.finished == false { recordVoiceCheck(text,seconds:nil,level:nil);return }
        guard !handleSessionInstruction(text) else { return }
        if !state.question.isEmpty { submitAnswer(text); return }
        guard commands.enqueue(text) else { fail("Command queue is full. Pending follow-ups were cleared; try again."); return }
        state.waitingRequests=commands.pending
        drainCommands()
    }
    func clearWaitingRequests() {
        commands.discardPending(); state.waitingRequests=[]
        discardPendingAudio()
    }
    func cancelCurrentTask() {
        autoCloseGeneration=UUID();generation=UUID();planner.cancel();clearReview();hidePointing();stopReading()
        try? input?.fileHandleForWriting.close();task?.terminate();task=nil;input=nil;workerSucceeded=false
        commands.finish(success:false);clearWaitingRequests()
        dialogue=[];originalGoal="";resolvedGoal="";flightPlan=nil
        state.question="";state.answer="";state.interpreted="";state.requestDraft=""
        state.busy=false;state.completedAt = .distantPast
        state.phase=state.recording ? "Listening" : "Ready"
        state.detail="Task cancelled. Changes already made are kept. \(state.recording ? "I’m listening for your next request." : "Type another request or start talking.")"
        hideCursor();showPanel(key:false)
    }
    func drainCommands() {
        guard task == nil, !state.busy, let goal=commands.next() else { return }
        autoCloseGeneration=UUID()
        state.waitingRequests=commands.pending; state.command=goal
        originalGoal=goal; dialogue=[]; resolvedGoal=""; flightPlan=nil; state.interpreted=""
        if handleLocalVoiceCommand(goal) { return }
        interpretCommand()
    }

    func interpretCommand() {
        guard let runtime else { fail("Local runtime is unavailable."); return }
        rememberTarget()
        if !state.localInterpreter { resolvedGoal=originalGoal; launchCommand(originalGoal); return }
        refreshModels()
        guard state.qwenInstalled else { fail("Download Qwen in Settings to interpret this request."); showSettings(); return }
        guard desktopReady else { fail("Complete permission setup first."); setupPermissions(); return }
        state.completedAt = .distantPast; state.busy=true; state.phase="Understanding locally"; state.detail="Qwen is interpreting your request."
        let token=UUID(); generation=token
        targetApp?.activate(options:[]); showPanel(key:false)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in
            guard let self, self.generation==token else { return }
            self.planner.interpret(runtime:runtime,goal:self.originalGoal,context:self.commands.context,dialogue:self.dialogue) { [weak self] plan in
                guard let self, self.generation==token else { return }
                guard plan["event"] as? String == "plan" else { self.fail(plan["text"] as? String ?? "Local interpretation failed."); return }
                if plan["action"] as? String == "clarify" {
                    guard self.dialogue.count<3 else { self.fail("Please start again with a more specific instruction."); return }
                    self.state.busy=false; self.state.question=plan["question"] as? String ?? "What should I do?"
                    self.state.answer=""; self.state.phase="Need one detail"; self.state.detail="Say or type an answer. Pending follow-ups were cleared."
                    self.commands.discardPending(); self.state.waitingRequests=[]
                    let resume=self.state.recording
                    self.discardPendingAudio()
                    self.showPanel(key:!resume)
                    self.presentPendingReview();self.clearReview()
                } else if plan["action"] as? String == "execute", let goal=plan["goal"] as? String, !goal.isEmpty {
                    self.resolvedGoal=goal; self.flightPlan=plan["flight"] as? [String:Any]; self.state.interpreted=goal; self.state.question=""; self.state.answer=""
                    self.launchCommand(goal)
                } else { self.fail("Local interpretation returned an invalid result.") }
            }
            self.showPanel(key:false)
        }
    }
    func submitAnswer(_ answer: String) {
        let text=answer.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !state.question.isEmpty, !state.busy, !text.isEmpty else { return }
        if handleSessionInstruction(text) { return }
        dialogue.append(["question":state.question,"answer":text]); state.question=""; state.answer=""
        interpretCommand()
    }

    func runCommand() {
        if !state.question.isEmpty { submitAnswer(state.answer); return }
        let goal=state.requestDraft.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        state.requestDraft=""
        acceptInstruction(goal)
    }
    func launchCommand(_ goal: String) {
        guard let runtime else { fail("Runtime unavailable. Rebuild with build.py."); return }
        guard desktopReady else { fail("Complete permission setup, then start listening again."); setupPermissions(); return }
        workerSucceeded=false;state.completedAt = .distantPast
        activityWindow?.resignKey(); activityWindow?.orderOut(nil); targetApp?.activate(options:[])
        state.busy=true; state.step=0; state.cost=0; state.phase="Working"; state.detail="\(state.shortcutLabel) or Escape stops the run."
        let token=UUID(); generation=token
        let process=Process(); let output=Pipe(); let stdin=Pipe(); input=stdin
        process.executableURL=URL(fileURLWithPath:runtime.python)
        var arguments=["-B","-u",runtime.worker,"--root",runtime.root,"--engine",state.engine,"--provider",state.provider]
        if state.preview { arguments.append("--preview") }
        if state.writerEnabled { arguments.append("--allow-writer") }
        process.arguments=arguments
        var environment=ProcessInfo.processInfo.environment
        for account in ["TYPESAFE_API_KEY","OPENROUTER_API_KEY"] {
            if let key=Credentials.read(account) { environment["NOTCHPILOT_"+account]=key }
        }
        process.environment=environment
        process.standardInput=stdin; process.standardOutput=output; process.standardError=FileHandle.nullDevice
        process.currentDirectoryURL=URL(fileURLWithPath:runtime.root); task=process
        let authorization=originalGoal + dialogue.map { "\nClarification answer: " + ($0["answer"] ?? "") }.joined()
        var request: [String:Any] = ["goal":goal,"context":commands.context,"authorization":authorization]
        if let targetApp,let targetWindowID {
            request["target"]=["pid":Int(targetApp.processIdentifier),"window_id":targetWindowID,
                               "app":targetApp.localizedName ?? ""]
        }
        if let flightPlan { request["flight"]=flightPlan }
        do { try process.run(); let data=try JSONSerialization.data(withJSONObject:request); stdin.fileHandleForWriting.write(data+Data([10])) }
        catch { fail("Could not start the desktop helper."); return }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            var buffer=Data()
            while true {
                let chunk=output.fileHandleForReading.availableData
                if chunk.isEmpty { break }; buffer.append(chunk)
                while let range=buffer.range(of:Data([10])) {
                    let line=buffer.subdata(in:0..<range.lowerBound); buffer.removeSubrange(0..<range.upperBound)
                    if let event=try? JSONSerialization.jsonObject(with:line) as? [String:Any] {
                        DispatchQueue.main.async { guard let self, self.generation==token else { return }; self.receive(event,token:token) }
                    }
                }
            }
            process.waitUntilExit()
            DispatchQueue.main.async {
                guard let self, self.generation==token else { return }
                self.task=nil; self.input=nil; self.hideCursor()
                if self.state.busy { self.fail("The helper exited before reporting a result. Pending instructions stopped."); return }
                self.commands.finish(success:self.workerSucceeded,resolved:self.resolvedGoal.isEmpty ? nil : self.resolvedGoal)
                self.state.waitingRequests=self.commands.pending
                if self.workerSucceeded {
                    self.drainCommands()
                    if !self.state.busy { self.scheduleAutoClose() }
                }
            }
        }
    }

    func receive(_ event: [String:Any], token: UUID) {
        guard generation==token else { return }
        if let cost=event["cost"] as? Double { state.cost=cost }
        if let step=event["step"] as? Int { state.step=step }
        switch event["event"] as? String {
        case "checkpoint":
            if state.reviewing {
                reviewToken=token;state.reviewReady=true
                presentPendingReview()
            } else { ack(token) }
        case "capture":
            showPanel(key:false)
            guard let path=event["path"] as? String else { ack(token);return }
            Task { @MainActor [weak self] in
                guard let self,self.generation==token else { return }
                do {
                    try await PilotScreenCapture.save(to:path)
                    self.ack(token)
                } catch {
                    guard self.generation==token else { return }
                    self.fail("Screen capture failed: \(error.localizedDescription)")
                }
            }
        case "target":
            (cursor.contentView as? CursorView)?.configure(event)
            state.detail=(event["label"] as? String ?? "Next action")+" · "+(event["input_mode"] as? String ?? "")
            showPanel(key:false)
            if let path=event["activate_bundle_path"] as? String,
               let app=NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path }) {
                // Activation requests must originate from the interactive host;
                // a headless Python helper can be denied foreground activation.
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(to:app)
                    app.activate(from:.current,options:[.activateAllWindows])
                } else { app.activate(options:[.activateAllWindows]) }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in self?.ack(token) }
                return
            }
            if let x=event["x"] as? Double, let y=event["y"] as? Double, let screen=NSScreen.screens.first {
                if cursorMotion==nil { cursorMotion=CursorMotion(window:cursor) }
                cursorMotion?.move(to:NSPoint(x:x,y:screen.frame.maxY-y)) { [weak self] in
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.07) { self?.ack(token) }
                }
            } else { ack(token) }
        case "status":
            state.detail=event["text"] as? String ?? "Working"; showPanel(key:false)
        case "action_end":
            cursorMotion?.actionFinished()
        case "open_folder":
            guard let path=event["path"] as? String else { fail("The folder path is missing.");return }
            if let finder=NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(to:finder)
                    finder.activate(from:.current,options:[.activateAllWindows])
                } else { finder.activate(options:[.activateAllWindows]) }
            }
            var isDirectory: ObjCBool=false
            guard FileManager.default.fileExists(atPath:path,isDirectory:&isDirectory),isDirectory.boolValue,
                  NSWorkspace.shared.open(URL(fileURLWithPath:path,isDirectory:true)) else {
                fail("Could not open the requested folder.");return
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in self?.ack(token) }
        case "host_text":
            guard let pid=event["pid"] as? Int,let window=event["window_id"] as? Int,
                  let front=NSWorkspace.shared.frontmostApplication,Int(front.processIdentifier)==pid,
                  HostKeyboard.windowIsFront(window,pid:front.processIdentifier,bundle:front.bundleIdentifier),
                  let text=event["text"] as? String,!text.isEmpty,text.utf16.count<=8000,
                  let field=event["focus"] as? [String:Any] else {
                fail("The target document changed before dictation. Nothing was typed.");return
            }
            do {
                voiceEditor.record(try HostKeyboard.insertText(text,spec:field,pid:front.processIdentifier,window:window,spacing:event["spacing"] as? Bool == true))
                ack(token)
            } catch { fail(error.localizedDescription) }
        case "host_key":
            guard let pid=event["pid"] as? Int,
                  let front=NSWorkspace.shared.frontmostApplication,Int(front.processIdentifier) == pid,
                  let key=event["key"] as? String,
                  let code=HostKeyboard.codes[key] else {
                fail("The active app changed before keyboard input. Nothing was typed.");return
            }
            if let window=event["window_id"] as? Int,!HostKeyboard.windowIsFront(window,pid:front.processIdentifier,bundle:front.bundleIdentifier) {
                fail("The target window changed before keyboard input. Nothing was typed.");return
            }
            if let field=event["focus"] as? [String:Any],!HostKeyboard.focus(field,pid:front.processIdentifier) {
                fail("Could not focus the requested text field. Nothing was typed.");return
            }
            if key=="escape" { setEscapeShortcut(active:false) }
            var flags: CGEventFlags=[]
            if event["command"] as? Bool == true { flags.insert(.maskCommand) }
            if event["shift"] as? Bool == true { flags.insert(.maskShift) }
            for down in [true,false] {
                guard let keyEvent=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down) else {
                    fail("Could not create keyboard input.");return
                }
                keyEvent.flags=down ? flags : []
                keyEvent.post(tap:.cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.08) { [weak self] in
                guard let self,self.generation==token else { return }
                if key=="escape" { self.setEscapeShortcut(active:true) }
                self.ack(token)
            }
        case "done","error":
            workerSucceeded=event["event"] as? String == "done" && event["success"] as? Bool == true
            let message=event["text"] as? String ?? "Stopped"
            if !workerSucceeded { fail(message + " Pending instructions stopped."); return }
            state.busy=false; state.phase=state.recording ? "Listening" : "Finished"
            state.detail=message;state.completedAt=Date(); hideCursor(); showPanel(key:false)
            presentPendingReview();clearReview()
        default: break
        }
    }
    func qaStatus() -> [String:Any] {
        let front=NSWorkspace.shared.frontmostApplication
        return ["bound":voiceEditor.target.map { [Int($0.pid),$0.window] } ?? [],
         "front":front.map { [Int($0.processIdentifier),HostKeyboard.frontWindow(pid:$0.processIdentifier,bundle:$0.bundleIdentifier) ?? -1] } ?? [],
         "phase":state.phase,"detail":state.detail,"busy":state.busy,"dictating":state.dictating,"sleeping":state.voiceSleeping,"recording":state.recording,"command":state.command,"interpreted":state.interpreted,
         "overlay":{ () -> String in
             switch pointing {
             case .numbers(let targets)?: return "numbers:"+targets.enumerated().map { "\($0.offset+1)=\($0.element.role):\($0.element.label)@\(Int($0.element.frame.midX)),\(Int($0.element.frame.midY))" }.joined(separator:"|")
             case .grid(let grid)?: return "grid:\(Int(grid.rect.minX)),\(Int(grid.rect.minY)),\(Int(grid.rect.width))x\(Int(grid.rect.height))"
             case nil: return ""
             }
         }(),
         "pending":commands.pending.count,"completedAt":state.completedAt.timeIntervalSince1970]
    }
    func ack(_ token: UUID) {
        guard generation==token, task?.isRunning==true else { return }
        input?.fileHandleForWriting.write(Data("continue\n".utf8))
    }
    func hideCursor() { cursorMotion?.hide();cursor?.orderOut(nil) }
    func discardPendingAudio() {
        audioEpoch=UUID(); speech?.discardPendingSpeech(epoch:audioEpoch)
        whisperSession.cancelPending(); transcribing=false
        for url in audioQueue { try? FileManager.default.removeItem(at:url) }; audioQueue.removeAll()
        if let url=transcribingURL { try? FileManager.default.removeItem(at:url) }; transcribingURL=nil
    }
    func stopAudio() {
        voiceGeneration=UUID(); startingVoice=false;pendingVoiceStart=false;speech?.stop(); speech=nil
        discardPendingAudio(); state.recording=false; state.level=0
    }
    func stop(close: Bool) {
        autoCloseGeneration=UUID()
        generation=UUID(); stopReading(); stopAudio(); planner.cancel();clearReview();hidePointing()
        if state.voiceCheck?.finished == false { endVoiceCheck() }
        state.dictating=false;state.voiceSleeping=false;voiceEditor.target=nil;voiceEditor.history.removeAll()
        try? input?.fileHandleForWriting.close();task?.terminate(); task=nil; input=nil; commands.cancel(); dialogue=[]; originalGoal=""; resolvedGoal=""
        state.question=""; state.answer=""; state.interpreted=""; state.requestDraft=""
        state.busy=false; state.waitingRequests=[]; state.phase="Stopped"; state.detail="Listening and all pending instructions stopped."
        hideCursor(); if close { panel.orderOut(nil);activityWindow?.orderOut(nil);preferences?.orderOut(nil);setEscapeShortcut(active:false) } else { showPanel(key:false) }
    }
    func autoCloseReady(at now: Date = Date()) -> Bool {
        state.closeWhenDone && pointing==nil && state.voiceCheck?.finished != false && !state.dictating && !state.voiceSleeping && !state.busy && !state.needsAttention && state.question.isEmpty && commands.active==nil && commands.pending.isEmpty &&
        activityWindow?.isVisible != true && preferences?.isVisible != true &&
        !transcribing && audioQueue.isEmpty && speech?.hasPendingSpeech != true && now.timeIntervalSince(state.lastSpeech)>1.4
    }
    func scheduleAutoClose() {
        guard state.closeWhenDone else { return }
        let token=UUID();autoCloseGeneration=token
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { [weak self] in
            guard let self,self.autoCloseGeneration==token,self.state.closeWhenDone,!self.state.needsAttention,!self.state.busy else { return }
            if self.autoCloseReady() {
                let result=self.state.detail
                self.stop(close:true);self.state.phase="Finished";self.state.detail=result
            } else { self.scheduleAutoClose() }
        }
    }
    func fail(_ message: String) {
        let requestedReview=pendingReview
        autoCloseGeneration=UUID()
        if state.recording {
            generation=UUID(); planner.cancel();clearReview(); try? input?.fileHandleForWriting.close();task?.terminate(); task=nil; input=nil
            commands.finish(success:false); commands.discardPending(); discardPendingAudio()
            dialogue=[]; originalGoal=""; resolvedGoal=""
            state.question=""; state.answer=""; state.interpreted=""; state.requestDraft=""
            state.busy=false; state.waitingRequests=[]; state.phase="Listening · needs attention"
            state.detail=message + " Still listening for your next instruction."
            hideCursor(); showPanel(key:false)
        } else {
            stop(close:false); state.phase="Needs attention"; state.detail=message
        }
        if let requestedReview {
            if requestedReview=="settings" { presentSettings() } else { presentActivity() }
        }
    }
    func refreshModels() {
        guard let runtime else { return }
        let resource=URL(fileURLWithPath:runtime.downloader).deletingLastPathComponent().appendingPathComponent("models.json")
        let manifest=(try? Data(contentsOf:resource)).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
        func installed(_ name: String, directory: String) -> Bool {
            let receiptURL=URL(fileURLWithPath:directory).appendingPathComponent(".\(name)-installed.json")
            guard let expected=manifest?[name] as? [String:Any],
                  let data=try? Data(contentsOf:receiptURL),let receipt=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                  NSDictionary(dictionary:expected).isEqual(to:receipt),let files=expected["files"] as? [[String:Any]] else { return false }
            return files.allSatisfy { file in
                guard let filename=file["name"] as? String, let size=file["size"] as? NSNumber,
                      let attrs=try? FileManager.default.attributesOfItem(atPath:directory+"/"+filename) else { return false }
                return (attrs[.size] as? NSNumber)==size
            }
        }
        state.qwenInstalled=installed("qwen",directory:runtime.qwen)
        let whisperDirectory=URL(fileURLWithPath:runtime.model).deletingLastPathComponent().path
        state.whisperInstalled=installed("whisper",directory:whisperDirectory)
        state.vadInstalled=installed("vad",directory:URL(fileURLWithPath:runtime.vadModel).deletingLastPathComponent().path)
    }
    var pendingModelDownloads: [String] = []
    func cancelModelDownload() {
        pendingModelDownloads=[]
        downloadTask?.terminate(); downloadTask=nil; state.downloading=false
        state.downloadStatus="Download cancelled. Verified files can be reused when you try again."; refreshModels()
    }
    func downloadModel(_ name: String) {
        if name == "essentials" {
            refreshModels()
            pendingModelDownloads = ["whisper","vad","qwen"].filter {
                $0 == "whisper" ? !state.whisperInstalled : $0 == "vad" ? !state.vadInstalled : state.localInterpreter && !state.qwenInstalled
            }
            guard !pendingModelDownloads.isEmpty else { return }
            downloadModel(pendingModelDownloads.removeFirst());return
        }
        guard downloadTask==nil, !state.busy, !state.recording, let runtime else { return }
        planner.cancel()
        let process=Process(); let output=Pipe()
        process.executableURL=URL(fileURLWithPath:runtime.python)
        process.arguments=["-B","-u",runtime.downloader,"--root",runtime.root,"--model",name]
        process.standardOutput=output; process.standardError=FileHandle.nullDevice
        downloadTask=process; state.downloading=true; state.downloadProgress=0; state.downloadStatus="Preparing download…"
        do { try process.run() } catch { downloadTask=nil; state.downloading=false; state.downloadStatus="Could not start the downloader."; return }
        DispatchQueue.global(qos:.utility).async { [weak self] in
            var buffer=Data()
            while true {
                let chunk=output.fileHandleForReading.availableData
                if chunk.isEmpty { break }; buffer.append(chunk)
                while let range=buffer.range(of:Data([10])) {
                    let line=buffer.subdata(in:0..<range.lowerBound); buffer.removeSubrange(0..<range.upperBound)
                    if let event=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any] {
                        DispatchQueue.main.async {
                            guard let self, self.downloadTask === process else { return }
                            self.state.downloadStatus=event["text"] as? String ?? "Downloading…"
                            if let progress=event["progress"] as? Double { self.state.downloadProgress=progress }
                        }
                    }
                }
            }
            process.waitUntilExit()
            DispatchQueue.main.async {
                guard let self, self.downloadTask === process else { return }
                self.downloadTask=nil; self.state.downloading=false; self.refreshModels()
                if process.terminationStatus != 0 {
                    self.pendingModelDownloads=[]
                    if !self.state.downloadStatus.hasPrefix("Download failed") { self.state.downloadStatus="Download interrupted. Try again." }
                } else if !self.pendingModelDownloads.isEmpty {
                    self.downloadModel(self.pendingModelDownloads.removeFirst())
                }
            }
        }
    }
    func refreshConnection() {
        let account=state.connectionProvider == "typesafe" ? "TYPESAFE_API_KEY" : "OPENROUTER_API_KEY"
        let environment=ProcessInfo.processInfo.environment
        let file=runtime.flatMap { try? String(contentsOfFile:$0.root+"/.env",encoding:.utf8) } ?? ""
        state.keyConfigured = !(Credentials.read(account) ?? "").isEmpty || !(environment[account] ?? "").isEmpty || PilotCopy.hasConfiguredKey(account,in:file)
    }
    func requestReview(_ page: String) -> Bool {
        guard state.busy && !state.reviewReady else { return false }
        rememberTarget();pendingReview=page;state.reviewing=true
        return true
    }
    func presentPendingReview() {
        guard let page=pendingReview else { return }
        pendingReview=nil
        if page=="settings" { presentSettings() } else { presentActivity() }
    }
    func clearReview() { pendingReview=nil;reviewToken=nil;state.reviewing=false;state.reviewReady=false }
    func resumeReviewedWork() {
        let token=reviewToken
        activityWindow?.resignKey();activityWindow?.orderOut(nil)
        preferences?.resignKey();preferences?.orderOut(nil)
        clearReview()
        // The controller restores and validates its exact target before input.
        if let token { ack(token) }
        showPanel(key:false)
    }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow)===voiceCheckWindow {
            if state.voiceCheck?.finished == false { endVoiceCheck() }
            state.voiceCheck=nil;return
        }
        if state.reviewing { resumeReviewedWork() }
    }
    @objc func showSettings() {
        guard !requestReview("settings") else { return }
        presentSettings()
    }
    func applyAppearance() {
        preferences?.appearance=state.appearance.native
        activityWindow?.appearance=state.appearance.native
    }
    func presentSettings() {
        rememberTarget();refreshConnection();refreshPermissions()
        if !state.accessReady || !state.modelsReady || !state.keyConfigured { state.settingsPage="Setup" }

        if preferences == nil {
            let height=min(CGFloat(720),(NSScreen.main?.visibleFrame.height ?? 900)-70)
            let view=NSHostingView(rootView:PreferencesView(state:state,draft:preferencesDraft).frame(width:620,height:height))
            preferences=NSWindow(contentRect:NSRect(x:0,y:0,width:588,height:510),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            preferences?.title="NotchPilot Settings"; preferences?.contentView=view
            preferences?.appearance=state.appearance.native
            preferences?.setContentSize(view.fittingSize)
            preferences?.isReleasedWhenClosed=false; preferences?.delegate=self; preferences?.center()
        }
        NSApp.activate(ignoringOtherApps:true); preferences?.makeKeyAndOrderFront(nil)
    }
    @objc func showActivity() {
        guard !requestReview("activity") else { return }
        presentActivity()
    }
    func presentActivity() {
        rememberTarget()
        preferences?.orderOut(nil)
        if activityWindow==nil {
            let height=min(CGFloat(620),(NSScreen.main?.visibleFrame.height ?? 900)-80)
            let view=NSHostingView(rootView:ScrollView { ActivityView(state:state) }
                .frame(width:460,height:height).background(PilotStyle.paper))
            activityWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:470,height:400),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            activityWindow?.title="NotchPilot · Commands and activity";activityWindow?.contentView=view
            activityWindow?.appearance=state.appearance.native;activityWindow?.setContentSize(view.fittingSize)
            activityWindow?.isReleasedWhenClosed=false;activityWindow?.delegate=self;activityWindow?.center()
        }
        NSApp.activate(ignoringOtherApps:true);activityWindow?.makeKeyAndOrderFront(nil)
    }
    func renderPreview(settings: Bool = false, activity: Bool = false, voiceCheck: Bool = false) {
        guard let view=(voiceCheck ? voiceCheckWindow?.contentView : activity ? activityWindow?.contentView : settings ? preferences?.contentView : panel.contentView), let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { NSApp.terminate(nil); return }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        let path=CommandLine.arguments.last ?? "/tmp/notchpilot-preview.png"
        if let data=bitmap.representation(using:.png,properties:[:]) { try? data.write(to:URL(fileURLWithPath:path)) }
        NSApp.terminate(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showFromMenu();return true
    }
    @objc func quit() { stop(close:true); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        whisperSession.shutdown()
        vadSession.shutdown()
        stop(close:true); downloadTask?.terminate(); permissionTask?.terminate()
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor=nil }
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey=nil }
        if let handler { RemoveEventHandler(handler); self.handler=nil }
    }
}
