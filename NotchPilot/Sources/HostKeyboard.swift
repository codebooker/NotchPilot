import AppKit
import ApplicationServices

enum HostKeyboard {
    static let codes: [String:CGKeyCode] = ["l":37,"t":17,"a":0,"return":36,"tab":48,"escape":53,"n":45,"s":1,"z":6,"f":3,"g":5,"o":31]

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value : nil
    }

    /// The unique element in the focused window with an observed role and frame (within 2 points).
    static func observed(_ spec: [String:Any], pid: pid_t, roles: Set<String>, limit: Int) -> AXUIElement? {
        guard let role=spec["role"] as? String,roles.contains(role),
              let frame=spec["frame"] as? [String:Double],
              let x=frame["x"],let y=frame["y"],let w=frame["w"],let h=frame["h"],w>0,h>0 else { return nil }
        let app=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.05)
        guard let raw=attribute(app,kAXFocusedWindowAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else { return nil }
        var nodes=[raw as! AXUIElement];var matches=[AXUIElement]();var count=0
        let deadline=Date().addingTimeInterval(1)
        while !nodes.isEmpty && count<limit && Date()<deadline {
            let node=nodes.removeFirst();count+=1
            if attribute(node,kAXRoleAttribute) as? String == role,
               let p=attribute(node,kAXPositionAttribute),let s=attribute(node,kAXSizeAttribute),
               CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() {
                var point=CGPoint.zero;var size=CGSize.zero
                if AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size),
                   abs(point.x-x)<2,abs(point.y-y)<2,abs(size.width-w)<2,abs(size.height-h)<2 { matches.append(node) }
            }
            nodes.append(contentsOf:(attribute(node,kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(100))
        }
        return matches.count==1 ? matches[0] : nil
    }
    static func focus(_ spec: [String:Any], pid: pid_t) -> Bool {
        guard let element=observed(spec,pid:pid,roles:["AXTextArea","AXTextField","AXComboBox"],limit:300),
              AXUIElementSetAttributeValue(element,kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success,
              let focused=attribute(AXUIElementCreateApplication(pid),kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(focused,element)
    }
    /// Presses a button the controller just observed, without Cua's post-press verification wait.
    /// The controller still observes the window afterwards.
    static func press(_ spec: [String:Any], pid: pid_t) -> Bool {
        guard let element=observed(spec,pid:pid,roles:["AXButton","AXCheckBox","AXRadioButton","AXDisclosureTriangle"],limit:1500),
              attribute(element,kAXEnabledAttribute) as? Bool != false else { return false }
        return AXUIElementPerformAction(element,kAXPressAction as CFString) == .success
    }

    static func windowIsFront(_ expected: Int, pid: pid_t, bundle: String?) -> Bool {
        frontWindow(pid:pid,bundle:bundle)==expected
    }

    static func insertion(_ text: String, into before: String, range: NSRange, spacing: Bool) -> (text: String, result: String)? {
        let original=before as NSString
        guard range.location>=0,range.length>=0,range.location<=original.length,range.length<=original.length-range.location else { return nil }
        var inserted=text
        if spacing && range.length==0 && range.location>0 && !text.isEmpty {
            let left=original.substring(to:range.location).last
            let right=original.substring(from:range.location).first
            // Add a boundary only after a word/sentence at the end of a word.
            // Mid-word insertion and deliberate whitespace remain literal.
            if let left,let first=text.first,!first.isWhitespace,
               (first.isLetter || first.isNumber),
               (left.isLetter || left.isNumber || ".!?;:,".contains(left)),
               right == nil || right?.isWhitespace == true {
                inserted=" "+text
            }
        }
        return (inserted,original.replacingCharacters(in:range,with:inserted))
    }

    static func insertText(_ text: String, spec: [String:Any], pid: pid_t, window: Int, spacing: Bool) throws -> DictationEdit {
        func problem(_ message:String) -> NSError { NSError(domain:"NotchPilot",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
        guard focus(spec,pid:pid) else { throw problem("Could not focus the document. Nothing was typed.") }
        let app=AXUIElementCreateApplication(pid)
        guard let raw=attribute(app,kAXFocusedUIElementAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else {
            throw problem("The document lost focus. Nothing was typed.")
        }
        let field=raw as! AXUIElement
        guard let before=attribute(field,kAXValueAttribute) as? String,
              let rawRange=attribute(field,kAXSelectedTextRangeAttribute),CFGetTypeID(rawRange)==AXValueGetTypeID() else {
            throw problem("This editor does not expose its insertion point. Nothing was typed.")
        }
        var selection=CFRange()
        guard AXValueGetValue(rawRange as! AXValue,.cfRange,&selection),
              let change=insertion(text,into:before,range:NSRange(location:selection.location,length:selection.length),spacing:spacing) else {
            throw problem("The document selection changed. Nothing was typed.")
        }
        guard let front=NSWorkspace.shared.frontmostApplication,front.processIdentifier==pid,
              windowIsFront(window,pid:pid,bundle:front.bundleIdentifier) else {
            throw problem("The target document changed before dictation. Nothing was typed.")
        }
        guard AXUIElementSetAttributeValue(field,kAXSelectedTextAttribute as CFString,change.text as CFString) == .success else {
            throw problem("This editor refused text insertion. The input was not retried.")
        }
        guard attribute(field,kAXValueAttribute) as? String == change.result else {
            throw problem("Text entry could not be verified. Check the document; the input was not retried.")
        }
        return DictationEdit(pid:pid,window:window,field:field,before:before,after:change.result,
                             range:NSRange(location:selection.location,length:selection.length),inserted:change.text)
    }

    static func frontWindow(pid: pid_t, bundle: String?) -> Int? {
        let rows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let windows=rows.filter { row in
            guard row[kCGWindowOwnerPID as String] as? Int == Int(pid),row[kCGWindowLayer as String] as? Int == 0 else { return false }
            if ["com.google.Chrome","com.microsoft.edgemac"].contains(bundle ?? "") { return !(row[kCGWindowName as String] as? String ?? "").isEmpty }
            return true
        }
        return windows.first?[kCGWindowNumber as String] as? Int
    }
}
