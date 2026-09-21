import AppKit

enum CursorOverlay {
    static func makeWindow() -> NSWindow {
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:CursorView.size),
                            styleMask:[.borderless],backing:.buffered,defer:false)
        window.backgroundColor = .clear;window.isOpaque=false;window.hasShadow=false
        window.contentView=CursorView(frame:NSRect(origin:.zero,size:CursorView.size))
        window.ignoresMouseEvents=true;window.level = .screenSaver
        window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        return window
    }
}

final class CursorView: NSView {
    // Room for the pointer, its action marks, and the click pulse around the hotspot.
    static let size=NSSize(width:64,height:64)
    static let hotspot=NSPoint(x:24,y:22)
    static let lavender=NSColor(srgbRed:0.69,green:0.54,blue:0.96,alpha:1)
    var pulse: CGFloat = 0 { didSet { needsDisplay=true } }
    var kind="click"
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func configure(_ event:[String:Any]) {
        kind=event["kind"] as? String ?? "click"
        needsDisplay=true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill();dirtyRect.fill(using:.copy)
        let violet=Self.lavender
        NSGraphicsContext.saveGraphicsState()
        let offset=NSAffineTransform();offset.translateX(by:Self.hotspot.x,yBy:Self.hotspot.y);offset.concat()
        // Small action marks echo the reference without a constant large glow.
        violet.withAlphaComponent(0.75).setStroke()
        if kind=="type" || kind=="key" {
            for i in 0..<3 {
                let tick=NSBezierPath();tick.move(to:NSPoint(x:CGFloat(i*5)-8,y:-10))
                tick.line(to:NSPoint(x:CGFloat(i*5)-8,y:-5));tick.lineWidth=1.5;tick.lineCapStyle = .round;tick.stroke()
            }
        } else {
            for radius in [CGFloat(9),CGFloat(14)] {
                let arc=NSBezierPath();arc.appendArc(withCenter:NSPoint(x:1,y:2),radius:radius,startAngle:185,endAngle:260)
                arc.lineWidth=1.5;arc.lineCapStyle = .round;arc.stroke()
            }
        }
        if pulse>0 {
            let radius=5+12*(1-pulse)
            violet.withAlphaComponent(pulse*0.55).setStroke()
            let ring=NSBezierPath(ovalIn:NSRect(x:-radius,y:-radius,width:radius*2,height:radius*2))
            ring.lineWidth=1.4;ring.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow=NSShadow();shadow.shadowColor=violet.withAlphaComponent(0.4)
        shadow.shadowBlurRadius=5;shadow.shadowOffset = .zero;shadow.set()
        let p=NSBezierPath()
        p.move(to:NSPoint(x:0,y:0))
        p.curve(to:NSPoint(x:4,y:0),controlPoint1:NSPoint(x:1,y:-1),controlPoint2:NSPoint(x:3,y:-1))
        p.line(to:NSPoint(x:23,y:9))
        p.curve(to:NSPoint(x:23,y:13),controlPoint1:NSPoint(x:26,y:10),controlPoint2:NSPoint(x:25,y:12))
        p.line(to:NSPoint(x:15,y:16));p.line(to:NSPoint(x:11,y:24))
        p.curve(to:NSPoint(x:7,y:24),controlPoint1:NSPoint(x:10,y:27),controlPoint2:NSPoint(x:8,y:27))
        p.line(to:NSPoint(x:0,y:4))
        p.curve(to:NSPoint(x:0,y:0),controlPoint1:NSPoint(x:-1,y:3),controlPoint2:NSPoint(x:-1,y:1));p.close()
        violet.setFill();p.fill()
        NSColor(calibratedWhite:1,alpha:0.96).setStroke();p.lineWidth=1.5;p.lineJoinStyle = .round;p.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
    }
}

enum CursorTiming {
    static func duration(distance: CGFloat, reducedMotion: Bool) -> Double {
        reducedMotion ? 0 : min(0.52,max(0.24,Double(distance)/1800))
    }
    static func ease(_ t: Double) -> Double { let t=min(1,max(0,t));return t*t*t*(t*(t*6-15)+10) }
}

final class CursorMotion {
    let window: NSWindow
    var timer: Timer?
    var hideWork: DispatchWorkItem?
    var positioned=false
    init(window:NSWindow) { self.window=window }
    var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    func hide() {
        timer?.invalidate();timer=nil;hideWork?.cancel();hideWork=nil
        window.orderOut(nil);window.alphaValue=1
    }
    func move(to point:NSPoint, arrival:@escaping ()->Void) {
        timer?.invalidate();hideWork?.cancel()
        (window.contentView as? CursorView)?.pulse=0
        let target=NSPoint(x:point.x-CursorView.hotspot.x,y:point.y-window.frame.height+CursorView.hotspot.y)
        if !positioned {
            window.setFrameOrigin(NSPoint(x:target.x-24,y:target.y+16));positioned=true
        }
        let start=window.frame.origin
        let distance=hypot(target.x-start.x,target.y-start.y)
        let duration=CursorTiming.duration(distance:distance,reducedMotion:reducedMotion)
        window.alphaValue=1;window.orderFrontRegardless()
        guard duration>0 else { window.setFrameOrigin(target);arrival();return }
        let began=ProcessInfo.processInfo.systemUptime
        let animation=Timer(timeInterval:1/60,repeats:true) { [weak self] timer in
            guard let self else { timer.invalidate();return }
            let t=min(1,(ProcessInfo.processInfo.systemUptime-began)/duration)
            let eased=CursorTiming.ease(t)
            self.window.setFrameOrigin(NSPoint(x:start.x+(target.x-start.x)*eased,y:start.y+(target.y-start.y)*eased))
            if t>=1 { timer.invalidate();self.timer=nil;arrival() }
        }
        timer=animation;RunLoop.main.add(animation,forMode:.common)
    }
    func actionFinished() {
        timer?.invalidate();hideWork?.cancel()
        let began=ProcessInfo.processInfo.systemUptime
        if !reducedMotion {
            let animation=Timer(timeInterval:1/60,repeats:true) { [weak self] timer in
                let t=min(1,(ProcessInfo.processInfo.systemUptime-began)/0.32)
                (self?.window.contentView as? CursorView)?.pulse=CGFloat(1-t)
                if t>=1 { timer.invalidate();self?.timer=nil }
            }
            timer=animation;RunLoop.main.add(animation,forMode:.common)
        }
        let work=DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.reducedMotion else { self.window.alphaValue=0;return }
            let start=ProcessInfo.processInfo.systemUptime
            let fade=Timer(timeInterval:1/60,repeats:true) { [weak self] timer in
                let t=min(1,(ProcessInfo.processInfo.systemUptime-start)/0.18)
                self?.window.alphaValue=1-CursorTiming.ease(t)
                if t>=1 { timer.invalidate();self?.timer=nil }
            }
            self.timer=fade;RunLoop.main.add(fade,forMode:.common)
        }
        hideWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.85,execute:work)
    }
}
