import AppKit
import ApplicationServices

/// Native NSSavePanel recovery. Never retries a Save click or approves replacement.
enum SaveRecovery {
    static func destination(_ path:String) throws -> URL {
        let expanded=(path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"),!expanded.contains("\n"),!expanded.contains("\0") else {
            throw VoiceEditor.problem("Say save as followed by a full path, for example ~/Desktop/My note.txt.")
        }
        let url=URL(fileURLWithPath:expanded).standardizedFileURL
        var directory:ObjCBool=false
        guard !url.lastPathComponent.isEmpty,
              FileManager.default.fileExists(atPath:url.deletingLastPathComponent().path,isDirectory:&directory),directory.boolValue else {
            throw VoiceEditor.problem("That destination folder does not exist. Choose an existing folder.")
        }
        guard !FileManager.default.fileExists(atPath:url.path) else {
            throw VoiceEditor.problem("That file already exists. Choose another name so the existing file stays intact.")
        }
        return url
    }
    /// Compares file identity, not path strings: folders such as /tmp are symlinks, and path
    /// standardization only strips /private once a file exists.
    static func sameFile(_ a:URL,_ b:URL) -> Bool {
        guard let first=try? a.resourceValues(forKeys:[.fileResourceIdentifierKey]).fileResourceIdentifier,
              let second=try? b.resourceValues(forKeys:[.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return first.isEqual(second)
    }
    static func identified(_ nodes:[AXUIElement],_ id:String) -> AXUIElement? {
        let found=nodes.filter { HostKeyboard.attribute($0,kAXIdentifierAttribute) as? String == id }
        return found.count==1 ? found[0] : nil
    }
    static func key(_ code:CGKeyCode,flags:CGEventFlags=[]) {
        for down in [true,false] {
            let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)
            event?.flags=down ? flags : [];event?.post(tap:.cghidEventTap)
        }
    }
    @MainActor static func save(path:String,pid:pid_t,window:Int,valid:() -> Bool,progress:(String) -> Void) async throws -> URL {
        var url=try destination(path)
        try VoiceEditor.requireFront(pid:pid,window:window)
        let application=AXUIElementCreateApplication(pid)
        guard let raw=HostKeyboard.attribute(application,kAXFocusedWindowAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else {
            throw VoiceEditor.problem("The document is no longer available.")
        }
        let owner=raw as! AXUIElement
        func check() throws {
            guard valid(),NSWorkspace.shared.frontmostApplication?.processIdentifier==pid,
                  let current=HostKeyboard.attribute(application,kAXFocusedWindowAttribute),CFGetTypeID(current)==AXUIElementGetTypeID() else { throw VoiceEditor.problem("Save stopped because the target document changed.") }
            if !CFEqual(current,owner) {
                var ancestor:AXUIElement? = (current as! AXUIElement)
                var belongs=false
                for _ in 0..<12 {
                    guard let node=ancestor else { break }
                    if CFEqual(node,owner) { belongs=true;break }
                    guard let parent=HostKeyboard.attribute(node,kAXParentAttribute),CFGetTypeID(parent)==AXUIElementGetTypeID() else { break }
                    ancestor = (parent as! AXUIElement)
                }
                if !belongs { belongs=VoiceEditor.nodes(pid:pid,root:owner).contains { CFEqual($0,current) } }
                guard belongs else { throw VoiceEditor.problem("Save stopped because the target document changed.") }
            }
        }
        func waitFor(_ predicate:() -> Bool) async throws {
            for _ in 0..<30 {
                try check();if predicate() { return }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            throw VoiceEditor.problem("The Save dialog did not expose the expected control. Nothing was retried.")
        }
        progress("Opening Save As")
        if identified(VoiceEditor.nodes(pid:pid),"saveAsNameTextField")==nil {
            try check();key(1,flags:[.maskCommand,.maskShift,.maskAlternate])
        }
        try await waitFor { identified(VoiceEditor.nodes(pid:pid),"saveAsNameTextField") != nil }
        let nodes=VoiceEditor.nodes(pid:pid)
        guard let name=identified(nodes,"saveAsNameTextField") else { throw VoiceEditor.problem("Save As is unavailable.") }
        if url.pathExtension.isEmpty,let currentName=HostKeyboard.attribute(name,kAXValueAttribute) as? String {
            let suffix=(currentName as NSString).pathExtension
            if !suffix.isEmpty { url=try destination(url.path+"."+suffix) }
        }
        // Save a copy without also saving changes back into the original document.
        if let keep=identified(nodes,"KeepChangesButton"),HostKeyboard.attribute(keep,kAXValueAttribute) as? Int==1 {
            try check()
            guard AXUIElementPerformAction(keep,kAXPressAction as CFString) == .success,
                  HostKeyboard.attribute(keep,kAXValueAttribute) as? Int==0 else { throw VoiceEditor.problem("Could not preserve the original document. Save stopped.") }
        }
        try check()
        guard AXUIElementSetAttributeValue(name,kAXValueAttribute as CFString,url.lastPathComponent as CFString) == .success,
              HostKeyboard.attribute(name,kAXValueAttribute) as? String==url.lastPathComponent else { throw VoiceEditor.problem("The filename could not be verified.") }
        progress("Choosing the destination folder")
        try check();key(5,flags:[.maskCommand,.maskShift])
        try await waitFor {
            guard let focused=HostKeyboard.attribute(application,kAXFocusedUIElementAttribute),CFGetTypeID(focused)==AXUIElementGetTypeID() else { return false }
            let field=focused as! AXUIElement
            return ["AXComboBox","AXTextField"].contains(HostKeyboard.attribute(field,kAXRoleAttribute) as? String ?? "") && !CFEqual(field,name)
        }
        guard let focused=HostKeyboard.attribute(application,kAXFocusedUIElementAttribute),CFGetTypeID(focused)==AXUIElementGetTypeID() else { throw VoiceEditor.problem("The folder field is unavailable.") }
        let folder=focused as! AXUIElement
        try check()
        guard AXUIElementSetAttributeValue(folder,kAXValueAttribute as CFString,url.deletingLastPathComponent().path as CFString) == .success,
              HostKeyboard.attribute(folder,kAXValueAttribute) as? String==url.deletingLastPathComponent().path else { throw VoiceEditor.problem("The destination could not be entered.") }
        try check();key(36)
        try await waitFor {
            let current=HostKeyboard.attribute(application,kAXFocusedUIElementAttribute)
            return current != nil && !CFEqual(current!,folder)
        }
        let fresh=VoiceEditor.nodes(pid:pid)
        guard let freshName=identified(fresh,"saveAsNameTextField"),HostKeyboard.attribute(freshName,kAXValueAttribute) as? String==url.lastPathComponent,
              // The default button's identifier is stable; its title is localized ("Save", "Sichern", …).
              let save=identified(fresh,"OKButton"),HostKeyboard.attribute(save,kAXEnabledAttribute) as? Bool==true else {
            throw VoiceEditor.problem("The Save dialog changed. No file was saved.")
        }
        _=try destination(url.path) // Check again for a file created while navigating.
        try check();progress("Saving and checking the file")
        guard AXUIElementPerformAction(save,kAXPressAction as CFString) == .success else { throw VoiceEditor.problem("The Save button refused the action.") }
        for _ in 0..<40 {
            guard valid() else { throw VoiceEditor.problem("Save cancelled. Check the destination for any completed save.") }
            if FileManager.default.fileExists(atPath:url.path) {
                let docs=VoiceEditor.nodes(pid:pid).compactMap { HostKeyboard.attribute($0,kAXDocumentAttribute) as? String }
                if docs.contains(where:{ URL(string:$0).map { sameFile($0,url) } ?? false }) { return url }
            }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        throw VoiceEditor.problem("Save could not be verified at the requested path. Check the dialog; no replacement was approved and Save was not retried.")
    }
}
