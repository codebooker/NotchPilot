import AppKit
import ApplicationServices

enum ClickKind: Equatable { case click, doubleClick, rightClick }

/// A control observed through Accessibility. Frames use global Quartz coordinates (top-left origin).
struct PointTarget {
    let element: AXUIElement
    let pid: pid_t
    let role: String
    let label: String
    let frame: CGRect
    let actions: [String]
}

enum PointTargets {
    static let roles: Set<String> = ["AXButton","AXCheckBox","AXRadioButton","AXPopUpButton","AXMenuButton","AXLink","AXTextField",
        "AXTextArea","AXComboBox","AXSlider","AXIncrementor","AXDisclosureTriangle","AXMenuItem","AXMenuBarItem","AXColorWell","AXCell"]
    static let chromium: Set<String> = ["com.google.Chrome","com.microsoft.edgemac","com.brave.Browser","company.thebrowser.Browser"]

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p=HostKeyboard.attribute(element,kAXPositionAttribute),let s=HostKeyboard.attribute(element,kAXSizeAttribute),
              CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID() else { return nil }
        var point=CGPoint.zero;var size=CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&point),AXValueGetValue(s as! AXValue,.cgSize,&size) else { return nil }
        return CGRect(origin:point,size:size)
    }
    static func label(_ element: AXUIElement) -> String {
        for key in [kAXTitleAttribute,kAXDescriptionAttribute,kAXPlaceholderValueAttribute,kAXHelpAttribute] {
            if let text=HostKeyboard.attribute(element,key) as? String,!text.trimmingCharacters(in:.whitespaces).isEmpty { return text }
        }
        if let title=HostKeyboard.attribute(element,kAXTitleUIElementAttribute),CFGetTypeID(title)==AXUIElementGetTypeID(),
           let text=HostKeyboard.attribute(title as! AXUIElement,kAXValueAttribute) as? String { return text }
        let role=HostKeyboard.attribute(element,kAXRoleAttribute) as? String ?? ""
        if ["AXButton","AXLink","AXMenuItem","AXCell"].contains(role),let text=HostKeyboard.attribute(element,kAXValueAttribute) as? String { return text }
        return ""
    }

    /// Actionable controls in the front window of `pid` (plus its sheets), visible on screen, in
    /// reading order. `menus` adds menu bar items and menu items, for clicking by name only.
    static func collect(pid: pid_t, bundle: String?, menus: Bool = false, limit: Int = 200) -> [PointTarget] {
        let app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.1)
        // Chromium builds its web accessibility tree only for assistive clients that ask.
        if chromium.contains(bundle ?? "") { AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,kCFBooleanTrue) }
        guard let raw=HostKeyboard.attribute(app,kAXFocusedWindowAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else { return [] }
        let window=raw as! AXUIElement
        guard let bounds=frame(window) else { return [] }
        let screens=NSScreen.screens.map { quartz($0.frame) }
        var roots=[window]
        if menus,let bar=HostKeyboard.attribute(app,kAXMenuBarAttribute),CFGetTypeID(bar)==AXUIElementGetTypeID() { roots.append(bar as! AXUIElement) }
        var queue=roots[...];var found:[PointTarget]=[];var visited=0
        let deadline=Date().addingTimeInterval(1.5)
        while let node=queue.popFirst(),visited<4000,Date()<deadline {
            visited+=1
            let role=HostKeyboard.attribute(node,kAXRoleAttribute) as? String ?? ""
            let actions=Self.actions(node)
            let menu=role=="AXMenuItem" || role=="AXMenuBarItem"
            if roles.contains(role) || (actions.contains(kAXPressAction) && !["AXGroup","AXWindow","AXScrollArea","AXWebArea","AXList","AXTable","AXOutline"].contains(role)),
               HostKeyboard.attribute(node,kAXEnabledAttribute) as? Bool != false,let box=frame(node) {
                let visible=box.width>=4 && box.height>=4 && box.intersects(bounds) && screens.contains { $0.intersects(box) }
                if (menu && menus) || visible,!found.contains(where:{ abs($0.frame.minX-box.minX)<2 && abs($0.frame.minY-box.minY)<2 && abs($0.frame.width-box.width)<2 }) {
                    found.append(PointTarget(element:node,pid:pid,role:role,label:label(node),frame:box,actions:actions))
                }
            }
            if role=="AXMenuItem" && !menus { continue }
            queue.append(contentsOf:(HostKeyboard.attribute(node,kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(400))
            if let sheets=HostKeyboard.attribute(node,"AXSheets") as? [AXUIElement] { queue.append(contentsOf:sheets) }
        }
        let windowTargets=found.filter { $0.role != "AXMenuItem" && $0.role != "AXMenuBarItem" }
        let ordered=readingOrder(windowTargets.map(\.frame)).map { windowTargets[$0] }
        return Array(ordered.prefix(limit))+found.filter { $0.role=="AXMenuItem" || $0.role=="AXMenuBarItem" }
    }
    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element,&names) == .success else { return [] }
        return names as? [String] ?? []
    }
    static func quartz(_ appKit: NSRect) -> CGRect {
        let top=NSScreen.screens.first?.frame.maxY ?? appKit.maxY
        return CGRect(x:appKit.minX,y:top-appKit.maxY,width:appKit.width,height:appKit.height)
    }
    static func appKit(_ quartz: CGRect) -> NSRect {
        let top=NSScreen.screens.first?.frame.maxY ?? quartz.maxY
        return NSRect(x:quartz.minX,y:top-quartz.maxY,width:quartz.width,height:quartz.height)
    }

    /// Exact names win; otherwise labels that start with the words, or contain them as whole words.
    static func matches(_ query: String, labels: [String]) -> [Int] {
        let wanted=VoiceCommandQueue.normalized(query)
        guard !wanted.isEmpty else { return [] }
        let names=labels.map(VoiceCommandQueue.normalized)
        let exact=names.indices.filter { names[$0]==wanted }
        if !exact.isEmpty { return exact }
        return names.indices.filter { names[$0].hasPrefix(wanted) || (" "+names[$0]+" ").contains(" "+wanted+" ") }
    }
    /// Rows top to bottom (items within 10 points share a row), then left to right.
    static func readingOrder(_ frames: [CGRect]) -> [Int] {
        var rows: [[Int]] = [];var rowTop = -CGFloat.infinity
        for index in frames.indices.sorted(by:{ frames[$0].minY<frames[$1].minY }) {
            if frames[index].minY-rowTop>10 { rows.append([]);rowTop=frames[index].minY }
            rows[rows.count-1].append(index)
        }
        return rows.flatMap { $0.sorted { frames[$0].minX<frames[$1].minX } }
    }
}

/// Dragon's MouseGrid: a 3 × 3 grid numbered 1–9 from the top left; each number zooms into a cell.
struct MouseGrid {
    private(set) var rect: CGRect
    private var history: [CGRect] = []
    init(_ rect: CGRect) { self.rect=rect }
    var center: CGPoint { CGPoint(x:rect.midX,y:rect.midY) }
    mutating func zoom(_ cell: Int) -> Bool {
        guard (1...9).contains(cell),rect.width>=9,rect.height>=9 else { return false }
        let column=CGFloat((cell-1)%3),row=CGFloat((cell-1)/3),width=rect.width/3,height=rect.height/3
        history.append(rect);rect=CGRect(x:rect.minX+column*width,y:rect.minY+row*height,width:width,height:height)
        return true
    }
    mutating func back() -> Bool {
        guard let previous=history.popLast() else { return false }
        rect=previous;return true
    }
}

enum Pointing {
    case numbers([PointTarget])
    case grid(MouseGrid)
}

/// Click-through overlay that draws numbered badges or the mouse grid above app windows and below
/// the NotchPilot strip and cursor.
final class PointingOverlay {
    private var window: NSWindow?
    private let view = PointingView(frame:.zero)

    func show(_ pointing: Pointing, on quartzBounds: CGRect) {
        let screen=NSScreen.screens.first { PointTargets.quartz($0.frame).intersects(quartzBounds) } ?? NSScreen.main ?? NSScreen.screens[0]
        if window==nil {
            let overlay=NSWindow(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false)
            overlay.isOpaque=false;overlay.backgroundColor = .clear;overlay.hasShadow=false;overlay.ignoresMouseEvents=true
            overlay.level=NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue-1)
            overlay.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary];overlay.contentView=view
            window=overlay
        }
        window?.setFrame(screen.frame,display:false)
        view.pointing=pointing;view.screenQuartz=PointTargets.quartz(screen.frame);view.needsDisplay=true
        window?.orderFrontRegardless()
    }
    func hide() { window?.orderOut(nil);view.pointing=nil }
    var isVisible: Bool { window?.isVisible == true }
}

final class PointingView: NSView {
    var pointing: Pointing?
    var screenQuartz = CGRect.zero
    override var isFlipped: Bool { true } // Match Quartz: y grows downward.
    override var isOpaque: Bool { false }
    private func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx:-screenQuartz.minX,dy:-screenQuartz.minY) }
    private func badge(_ text: String, at point: CGPoint, size: CGFloat, centered: Bool = false) {
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:size,weight:.semibold),.foregroundColor:NSColor.white]
        let label=text as NSString;let measured=label.size(withAttributes:attributes)
        var box=CGRect(x:point.x,y:point.y,width:max(measured.width+10,measured.height+4),height:measured.height+4)
        if centered { box.origin=CGPoint(x:point.x-box.width/2,y:point.y-box.height/2) }
        box.origin.x=min(max(box.minX,2),bounds.width-box.width-2);box.origin.y=min(max(box.minY,2),bounds.height-box.height-2)
        let pill=NSBezierPath(roundedRect:box,xRadius:box.height/2,yRadius:box.height/2)
        NSColor(srgbRed:0.17,green:0.15,blue:0.25,alpha:0.94).setFill();pill.fill()
        CursorView.lavender.setStroke();pill.lineWidth=1.5;pill.stroke()
        label.draw(at:CGPoint(x:box.midX-measured.width/2,y:box.minY+2),withAttributes:attributes)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill();dirtyRect.fill(using:.copy)
        switch pointing {
        case .numbers(let targets):
            for (index,target) in targets.enumerated() {
                let box=local(target.frame)
                CursorView.lavender.withAlphaComponent(0.55).setStroke()
                let outline=NSBezierPath(roundedRect:box,xRadius:3,yRadius:3);outline.lineWidth=1;outline.stroke()
                badge("\(index+1)",at:CGPoint(x:box.minX-4,y:box.minY-8),size:11)
            }
        case .grid(let grid):
            let area=local(grid.rect)
            NSColor.black.withAlphaComponent(0.08).setFill();area.fill(using:.sourceOver)
            for i in 0...3 {
                let x=area.minX+area.width*CGFloat(i)/3,y=area.minY+area.height*CGFloat(i)/3
                for (from,to) in [(CGPoint(x:x,y:area.minY),CGPoint(x:x,y:area.maxY)),(CGPoint(x:area.minX,y:y),CGPoint(x:area.maxX,y:y))] {
                    let line=NSBezierPath();line.move(to:from);line.line(to:to)
                    NSColor.white.withAlphaComponent(0.8).setStroke();line.lineWidth=3;line.stroke()
                    CursorView.lavender.setStroke();line.lineWidth=1.5;line.stroke()
                }
            }
            let size=min(max(min(area.width,area.height)/9,10),28)
            for cell in 1...9 {
                let column=CGFloat((cell-1)%3),row=CGFloat((cell-1)/3)
                let center=CGPoint(x:area.minX+area.width*(column+0.5)/3,y:area.minY+area.height*(row+0.5)/3)
                badge("\(cell)",at:center,size:size,centered:true)
            }
        case nil: break
        }
    }
}

/// Clicks through Accessibility where the control supports it; otherwise a real mouse event.
enum PointerInput {
    static func perform(_ kind: ClickKind, on target: PointTarget) {
        let center=CGPoint(x:target.frame.midX,y:target.frame.midY)
        switch kind {
        case .click:
            // Focus a text field without moving its caret to wherever the center happens to fall.
            if ["AXTextField","AXTextArea","AXComboBox"].contains(target.role) {
                if AXUIElementSetAttributeValue(target.element,kAXFocusedAttribute as CFString,kCFBooleanTrue) != .success { click(.click,at:center) }
            } else if target.actions.contains(kAXPressAction),AXUIElementPerformAction(target.element,kAXPressAction as CFString) == .success {
            } else { click(.click,at:center) }
        case .rightClick:
            if target.actions.contains(kAXShowMenuAction),AXUIElementPerformAction(target.element,kAXShowMenuAction as CFString) == .success {
            } else { click(.rightClick,at:center) }
        case .doubleClick: click(.doubleClick,at:center)
        }
    }
    static func click(_ kind: ClickKind, at point: CGPoint) {
        let right=kind == .rightClick
        CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap)
        for count in 1...(kind == .doubleClick ? 2 : 1) {
            for down in [true,false] {
                let type:CGEventType=right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .leftMouseDown : .leftMouseUp)
                let event=CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:right ? .right : .left)
                event?.setIntegerValueField(.mouseEventClickState,value:Int64(count))
                event?.post(tap:.cghidEventTap)
            }
        }
    }
}
