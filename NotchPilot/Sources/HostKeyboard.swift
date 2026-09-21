import AppKit
import ApplicationServices

enum HostKeyboard {
    static let codes: [String:CGKeyCode] = ["l":37,"t":17,"a":0,"return":36,"tab":48,"escape":53,"n":45,"s":1,"z":6,"f":3,"g":5,"o":31]

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value : nil
    }

    static func focus(_ spec: [String:Any], pid: pid_t) -> Bool {
        guard let role=spec["role"] as? String,["AXTextArea","AXTextField","AXComboBox"].contains(role),
              let frame=spec["frame"] as? [String:Double],
              let x=frame["x"],let y=frame["y"],let w=frame["w"],let h=frame["h"],w>0,h>0 else { return false }
        let app=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.05)
        guard let raw=attribute(app,kAXFocusedWindowAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else { return false }
        var nodes=[raw as! AXUIElement];var matches=[AXUIElement]();var count=0
        let deadline=Date().addingTimeInterval(1)
        while !nodes.isEmpty && count<300 && Date()<deadline {
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
        guard matches.count==1,AXUIElementSetAttributeValue(matches[0],kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success,
              let focused=attribute(app,kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(focused,matches[0])
    }

    static func windowIsFront(_ expected: Int, pid: pid_t, bundle: String?) -> Bool {
        let rows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let windows=rows.filter { row in
            guard row[kCGWindowOwnerPID as String] as? Int == Int(pid),row[kCGWindowLayer as String] as? Int == 0 else { return false }
            if ["com.google.Chrome","com.microsoft.edgemac"].contains(bundle ?? "") { return !(row[kCGWindowName as String] as? String ?? "").isEmpty }
            return true
        }
        return windows.first?[kCGWindowNumber as String] as? Int == expected
    }
}
