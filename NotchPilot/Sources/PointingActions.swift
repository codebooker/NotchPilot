import AppKit

extension AppDelegate {
    /// Numbers, click by name, and the mouse grid. Returns false only when a dictated phrase that
    /// starts with "click" matches nothing, so it should be typed as prose instead.
    @MainActor func handlePointing(_ command: VoiceEditCommand, token: UUID) async throws -> Bool {
        guard let front=NSWorkspace.shared.frontmostApplication,front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw VoiceEditor.problem("Bring the app you want to control to the front first.")
        }
        switch command {
        case .showNumbers:
            let targets=PointTargets.collect(pid:front.processIdentifier,bundle:front.bundleIdentifier)
            guard !targets.isEmpty else { throw VoiceEditor.problem("I couldn't find controls in this window. Try mouse grid instead.") }
            showPointing(.numbers(targets))
            finishVoiceAction("\(targets.count) controls numbered. Say a number, or double click or right click and a number. Say hide numbers to close.",token:token)
        case .hideOverlay:
            hidePointing();finishVoiceAction("Hidden. Ready for your next request.",token:token)
        case .mouseGrid:
            showPointing(.grid(MouseGrid(frontScreen(front))))
            finishVoiceAction("Say a number to zoom in, then click, double click, or right click. Say go back or hide grid.",token:token)
        case .gridBack:
            guard case .grid(var grid)=pointing,grid.back() else { throw VoiceEditor.problem("The grid is already at full size.") }
            showPointing(.grid(grid));finishVoiceAction("Zoomed out.",token:token)
        case .number(let number):
            if case .grid(var grid)=pointing {
                guard grid.zoom(number) else { throw VoiceEditor.problem("Say a number from 1 to 9, or click.") }
                showPointing(.grid(grid));finishVoiceAction("Say another number to zoom, or click.",token:token)
            } else { try await clickNumbered(number,.click,token:token) }
        case .choose(let number,let kind):
            if case .grid(var grid)=pointing {
                guard grid.zoom(number) else { throw VoiceEditor.problem("Say a number from 1 to 9, or click.") }
                try await clickPoint(grid.center,kind,label:"cell \(number)",app:front,token:token)
            } else { try await clickNumbered(number,kind,token:token) }
        case .pointerClick(let kind):
            if case .grid(let grid)=pointing { try await clickPoint(grid.center,kind,label:"the grid",app:front,token:token) }
            else {
                let mouse=NSEvent.mouseLocation
                try await clickPoint(PointTargets.quartz(NSRect(origin:mouse,size:.zero)).origin,kind,label:"the pointer",app:front,token:token)
            }
        case .clickNamed(let name,let kind):
            let targets=PointTargets.collect(pid:front.processIdentifier,bundle:front.bundleIdentifier,menus:true)
            let visible=targets.filter { !["AXMenuItem","AXMenuBarItem"].contains($0.role) }
            var candidates=PointTargets.matches(name,labels:visible.map(\.label)).map { visible[$0] }
            if candidates.isEmpty {
                let menus=targets.filter { ["AXMenuItem","AXMenuBarItem"].contains($0.role) }
                candidates=PointTargets.matches(name,labels:menus.map(\.label)).map { menus[$0] }
                if candidates.count>1 { throw VoiceEditor.problem("Several menu items match “\(name)”. Say more of the name.") }
            }
            if candidates.isEmpty {
                if state.dictating { return false }
                throw VoiceEditor.problem("I don't see “\(name)”. Say show numbers to choose it by number.")
            }
            if candidates.count==1 { try await click(candidates[0],kind,token:token) }
            else {
                showPointing(.numbers(candidates))
                finishVoiceAction("\(candidates.count) controls match “\(name)”. Say the number you want.",token:token)
            }
        default: return false
        }
        return true
    }

    func showPointing(_ value: Pointing) {
        pointing=value
        let bounds: CGRect
        switch value {
        case .numbers(let targets): bounds=targets.first?.frame ?? .zero
        case .grid(let grid): bounds=grid.rect
        }
        pointingOverlay.show(value,on:bounds)
    }
    func hidePointing() { pointing=nil;pointingOverlay.hide() }

    /// The screen under the front window, in Quartz coordinates, for the grid.
    func frontScreen(_ app: NSRunningApplication) -> CGRect {
        let window=AXUIElementCreateApplication(app.processIdentifier)
        if let raw=HostKeyboard.attribute(window,kAXFocusedWindowAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID(),
           let frame=PointTargets.frame(raw as! AXUIElement),
           let screen=NSScreen.screens.first(where:{ PointTargets.quartz($0.frame).contains(CGPoint(x:frame.midX,y:frame.midY)) }) {
            return PointTargets.quartz(screen.frame)
        }
        return PointTargets.quartz((NSScreen.main ?? NSScreen.screens[0]).frame)
    }

    @MainActor func clickNumbered(_ number: Int, _ kind: ClickKind, token: UUID) async throws {
        guard case .numbers(let targets)=pointing else { throw VoiceEditor.problem("Say show numbers first, then the number.") }
        guard targets.indices.contains(number-1) else { throw VoiceEditor.problem("Say a number from 1 to \(targets.count).") }
        try await click(targets[number-1],kind,token:token)
    }

    /// Re-checks the control before input: same app in front and the same place on screen.
    @MainActor func click(_ target: PointTarget, _ kind: ClickKind, token: UUID) async throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier==target.pid else {
            hidePointing();throw VoiceEditor.problem("The app changed. Say show numbers again.")
        }
        let menu=["AXMenuItem","AXMenuBarItem"].contains(target.role)
        if !menu {
            guard let now=PointTargets.frame(target.element),abs(now.minX-target.frame.minX)<4,abs(now.minY-target.frame.minY)<4 else {
                hidePointing();throw VoiceEditor.problem("The window changed. Say show numbers again.")
            }
        }
        hidePointing()
        let name=target.label.isEmpty ? "that control" : "“\(target.label)”"
        if !menu { await moveCursor(to:CGPoint(x:target.frame.midX,y:target.frame.midY),kind:kind,token:token) }
        guard generation==token else { return }
        PointerInput.perform(kind,on:target)
        cursorMotion?.actionFinished()
        finishVoiceAction((kind == .doubleClick ? "Double-clicked " : kind == .rightClick ? "Right-clicked " : "Clicked ")+name+".",token:token)
    }

    @MainActor func clickPoint(_ point: CGPoint, _ kind: ClickKind, label: String, app: NSRunningApplication, token: UUID) async throws {
        hidePointing()
        await moveCursor(to:point,kind:kind,token:token)
        guard generation==token,NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else {
            throw VoiceEditor.problem("The app changed before the click. Nothing was clicked.")
        }
        PointerInput.click(kind,at:point)
        cursorMotion?.actionFinished()
        finishVoiceAction((kind == .doubleClick ? "Double-clicked " : kind == .rightClick ? "Right-clicked " : "Clicked ")+label+".",token:token)
    }

    /// Shows the NotchPilot cursor travelling to the target, so the user sees where input goes.
    @MainActor func moveCursor(to point: CGPoint, kind: ClickKind, token: UUID) async {
        guard let cursor else { return }
        if cursorMotion==nil { cursorMotion=CursorMotion(window:cursor) }
        (cursor.contentView as? CursorView)?.configure(["kind":"click","app_name":NSWorkspace.shared.frontmostApplication?.localizedName ?? ""])
        let appKit=PointTargets.appKit(CGRect(origin:point,size:.zero)).origin
        // A cancelled animation never arrives, so resume after its longest duration regardless.
        await withCheckedContinuation { (done: CheckedContinuation<Void,Never>) in
            var resumed=false
            let finish={ if !resumed { resumed=true;done.resume() } }
            cursorMotion?.move(to:appKit) { finish() }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.8) { finish() }
        }
    }
}
