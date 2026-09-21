import AppKit
import ApplicationServices

enum VoiceEditCommand: Equatable {
    case start, end, insert(String), scratch, select(String), replace(String,String), beginning, endOfDocument
    case saveAs(String), openApp(String), key(String), help
    static func parse(_ text: String) -> VoiceEditCommand? {
        let clean=text.trimmingCharacters(in:.whitespacesAndNewlines)
        let normalized=VoiceCommandQueue.normalized(clean)
        switch normalized {
        case "start dictating","start dictation","dictation mode","write this down": return .start
        case "done dictating","stop dictating","command mode": return .end
        case "new paragraph": return .insert("\n\n")
        case "new line": return .insert("\n")
        case "scratch that","undo my last dictation","undo my last sentence": return .scratch
        case "go to beginning","go to the beginning","go to beginning of document": return .beginning
        case "go to end","go to the end","go to end of document": return .endOfDocument
        case "what can i say","show voice commands","voice help": return .help
        case "next field","press tab": return .key("tab")
        case "previous field","press shift tab": return .key("backtab")
        case "press enter","press return": return .key("return")
        case "move left","press left arrow": return .key("left")
        case "move right","press right arrow": return .key("right")
        case "move up","press up arrow": return .key("up")
        case "move down","press down arrow": return .key("down")
        case "page down","scroll down": return .key("pagedown")
        case "page up","scroll up": return .key("pageup")
        default: break
        }
        let apps=["textedit":"com.apple.TextEdit","safari":"com.apple.Safari","finder":"com.apple.finder",
                  "calculator":"com.apple.calculator","google chrome":"com.google.Chrome","notes":"com.apple.Notes","mail":"com.apple.mail"]
        for (name,bundle) in apps where ["open "+name,"switch to "+name,"launch "+name].contains(normalized) { return .openApp(bundle) }
        func parts(_ pattern:String) -> [String]? {
            guard let regex=try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive,.dotMatchesLineSeparators]),
                  let match=regex.firstMatch(in:clean,range:NSRange(clean.startIndex...,in:clean)) else { return nil }
            return (1..<match.numberOfRanges).map { (clean as NSString).substring(with:match.range(at:$0)) }
        }
        if let p=parts("^save(?: (?:it|this|the document))? as (.+?) (?:on|in|to) (?:my |the )?(desktop|documents)[.!]?$" ) {
            let folder=p[1].lowercased()=="desktop" ? "Desktop" : "Documents"
            return .saveAs("~/"+folder+"/"+p[0].replacingOccurrences(of:" dot ",with:"."))
        }
        func argument(_ value:String) -> String {
            if value.hasPrefix("\"") && value.hasSuffix("\"") { return String(value.dropFirst().dropLast()) }
            return value.hasSuffix(".") ? String(value.dropLast()) : value
        }
        if let p=parts("^(?:replace|change) (.+?) (?:with|to) (.+)$") { return .replace(argument(p[0]),argument(p[1])) }
        if let p=parts("^select (.+)$") { return .select(argument(p[0])) }
        // Paths are literal. Do not remove a final dot from an actual filename.
        if let p=parts("^save(?: (?:it|this|the document))? as (.+)$") { return .saveAs(p[0].trimmingCharacters(in:CharacterSet(charactersIn:"\"“”"))) }
        if let p=parts("^(?:type exactly|literal text) (.+)$") { return .insert(p[0]) }
        return nil
    }
    /// During dictation, a phrase that only resembles a command is typed instead, as Dragon and
    /// Voice Control do: "Select the best option" is text unless that phrase is in the document.
    /// Unreadable text (nil) is not prose, so the editor problem is reported rather than guessed.
    func isProse(in document: String?) -> Bool {
        switch self {
        case .saveAs(let path): return !path.hasPrefix("/") && !path.hasPrefix("~")
        case .select(let phrase),.replace(let phrase,_):
            guard let document else { return false }
            return (document as NSString).range(of:phrase,options:.caseInsensitive).location==NSNotFound
        default: return false
        }
    }
}

struct DictationEdit {
    let pid: pid_t
    let window: Int
    let field: AXUIElement
    let before: String
    let after: String
    let range: NSRange
    let inserted: String
}

final class VoiceEditor {
    var history: [DictationEdit] = []
    var target: (pid: pid_t, window: Int)?
    static func problem(_ text:String) -> NSError { NSError(domain:"NotchPilot",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
    func record(_ edit: DictationEdit) { history.append(edit);history=Array(history.suffix(20)) }

    static func nodes(pid: pid_t, root: AXUIElement? = nil) -> [AXUIElement] {
        let app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.05)
        var queue=root.map { [$0] } ?? (HostKeyboard.attribute(app,kAXWindowsAttribute) as? [AXUIElement] ?? [])
        var result=[AXUIElement]();let deadline=Date().addingTimeInterval(1)
        while !queue.isEmpty && result.count<500 && Date()<deadline {
            let node=queue.removeFirst()
            if result.contains(where:{CFEqual($0,node)}) { continue }
            result.append(node)
            for key in [kAXChildrenAttribute,"AXSheets"] {
                queue.append(contentsOf:(HostKeyboard.attribute(node,key) as? [AXUIElement] ?? []).prefix(100))
            }
        }
        return result
    }
    static func requireFront(pid: pid_t, window: Int) throws {
        guard let front=NSWorkspace.shared.frontmostApplication,front.processIdentifier==pid,
              HostKeyboard.windowIsFront(window,pid:pid,bundle:front.bundleIdentifier) else {
            throw problem("The document changed. Return to it or say command mode, then start dictating in the new document.")
        }
    }
    static func spec(_ field: AXUIElement) -> [String:Any]? {
        guard let p=HostKeyboard.attribute(field,kAXPositionAttribute),let s=HostKeyboard.attribute(field,kAXSizeAttribute),
              CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID(),
              let role=HostKeyboard.attribute(field,kAXRoleAttribute) as? String else { return nil }
        var point=CGPoint.zero;var size=CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size) else { return nil }
        return ["role":role,"frame":["x":Double(point.x),"y":Double(point.y),"w":Double(size.width),"h":Double(size.height)]]
    }
    func field(pid: pid_t, window: Int) throws -> AXUIElement {
        try Self.requireFront(pid:pid,window:window)
        let app=AXUIElementCreateApplication(pid)
        if let raw=HostKeyboard.attribute(app,kAXFocusedUIElementAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() {
            let element=raw as! AXUIElement
            if ["AXTextArea","AXTextField"].contains(HostKeyboard.attribute(element,kAXRoleAttribute) as? String ?? ""),
               HostKeyboard.attribute(element,kAXSelectedTextRangeAttribute) != nil { return element }
        }
        // Restrict candidates to the focused window, never another document.
        guard let raw=HostKeyboard.attribute(app,kAXFocusedWindowAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else { throw Self.problem("Select a document to begin dictating.") }
        let root=raw as! AXUIElement
        let candidates=Self.nodes(pid:pid,root:root).filter {
            HostKeyboard.attribute($0,kAXRoleAttribute) as? String == "AXTextArea"
        }
        guard candidates.count==1 else { throw Self.problem("Choose the text area first. I could not identify one editable document.") }
        return candidates[0]
    }
    /// The bound document's text, or nil when it is not in front or does not expose its value.
    func documentText(pid: pid_t, window: Int) -> String? {
        (try? field(pid:pid,window:window)).flatMap { HostKeyboard.attribute($0,kAXValueAttribute) as? String }
    }
    func insert(_ text:String,pid:pid_t,window:Int,spacing:Bool=true) throws {
        let element=try field(pid:pid,window:window)
        guard let spec=Self.spec(element) else { throw Self.problem("The editor does not expose a usable text area.") }
        record(try HostKeyboard.insertText(text,spec:spec,pid:pid,window:window,spacing:spacing))
    }
    static func uniqueRange(_ phrase:String,in text:String) -> NSRange? {
        guard !phrase.isEmpty else { return nil }
        let source=text as NSString
        let first=source.range(of:phrase,options:.caseInsensitive)
        guard first.location != NSNotFound else { return nil }
        let rest=NSRange(location:NSMaxRange(first),length:source.length-NSMaxRange(first))
        return source.range(of:phrase,options:.caseInsensitive,range:rest).location==NSNotFound ? first : nil
    }
    static func selectRange(_ range:NSRange,field:AXUIElement) throws {
        var cf=CFRange(location:range.location,length:range.length)
        guard let value=AXValueCreate(.cfRange,&cf),AXUIElementSetAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,value) == .success else { throw problem("This editor could not select that text.") }
        guard let selected=HostKeyboard.attribute(field,kAXSelectedTextRangeAttribute),CFGetTypeID(selected)==AXValueGetTypeID() else { throw problem("The selection could not be verified.") }
        var actual=CFRange();AXValueGetValue(selected as! AXValue,.cfRange,&actual)
        guard actual.location==range.location && actual.length==range.length else { throw problem("The selection changed before editing.") }
    }
    func edit(_ command:VoiceEditCommand,pid:pid_t,window:Int) throws {
        let element=try field(pid:pid,window:window)
        guard let text=HostKeyboard.attribute(element,kAXValueAttribute) as? String,text.utf16.count<=200000 else { throw Self.problem("This editor does not expose its text for corrections.") }
        switch command {
        case .scratch:
            guard let last=history.last,last.pid==pid,last.window==window,CFEqual(last.field,element),last.after==text else {
                throw Self.problem("The document changed since my last edit. Nothing was undone. Select the words to correct instead.")
            }
            try Self.selectRange(NSRange(location:last.range.location,length:last.inserted.utf16.count),field:element)
            try Self.requireFront(pid:pid,window:window)
            let previous=(last.before as NSString).substring(with:last.range)
            guard AXUIElementSetAttributeValue(element,kAXSelectedTextAttribute as CFString,previous as CFString) == .success,
                  HostKeyboard.attribute(element,kAXValueAttribute) as? String==last.before else { throw Self.problem("Undo could not be verified. Check the document; it was not retried.") }
            history.removeLast()
        case .select(let phrase),.replace(let phrase,_):
            guard let range=Self.uniqueRange(phrase,in:text) else { throw Self.problem("That text is missing or appears more than once. Say a longer, unique phrase.") }
            try Self.requireFront(pid:pid,window:window);try Self.selectRange(range,field:element)
            if case .replace(_,let replacement)=command { try insert(replacement,pid:pid,window:window,spacing:false) }
        case .beginning: try Self.selectRange(NSRange(location:0,length:0),field:element)
        case .endOfDocument: try Self.selectRange(NSRange(location:text.utf16.count,length:0),field:element)
        default: break
        }
    }
}
