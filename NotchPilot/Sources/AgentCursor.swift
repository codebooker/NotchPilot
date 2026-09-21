import AppKit

final class CursorView: NSView {
    // Transparent space allows the badge to move away from screen edges without
    // shifting the pointer's hotspot or the actual input target.
    static let size=NSSize(width:330,height:124)
    static let hotspot=NSPoint(x:165,y:40)
    static let lavender=NSColor(srgbRed:0.69,green:0.54,blue:0.96,alpha:1)
    var pulse: CGFloat = 0 { didSet { needsDisplay=true } }
    var kind="click"
    var deliveryMode=""
    var appName=""
    var badgeOrigin=NSPoint(x:88,y:82)
    override var isFlipped: Bool { true }

    func configure(_ event:[String:Any]) {
        kind=event["kind"] as? String ?? "click"
        deliveryMode=event["delivery_mode"] as? String ?? ""
        appName=event["app_name"] as? String ?? ""
        needsDisplay=true
    }
    func placeBadge(at point:NSPoint,on screen:NSRect) {
        let windowX=point.x-Self.hotspot.x
        let x=min(max(Self.hotspot.x-77,screen.minX+6-windowX),screen.maxX-160-windowX)
        // Flip the badge above the pointer near the bottom of the screen.
        badgeOrigin=NSPoint(x:x,y:point.y-68<screen.minY ? 0 : 82)
        needsDisplay=true
    }
    func symbol(_ name:String,in rect:NSRect,color:NSColor) {
        guard let image=NSImage(systemSymbolName:name,accessibilityDescription:nil)?
            .withSymbolConfiguration(.init(pointSize:12,weight:.medium)) else { return }
        let tinted=NSImage(size:image.size)
        tinted.lockFocus();image.draw(at:.zero,from:.zero,operation:.sourceOver,fraction:1)
        color.setFill();NSRect(origin:.zero,size:image.size).fill(using:.sourceIn);tinted.unlockFocus()
        tinted.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    }
    override func draw(_ dirtyRect: NSRect) {
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

        let badge=NSRect(origin:badgeOrigin,size:NSSize(width:154,height:26))
        let pill=NSBezierPath(roundedRect:badge,xRadius:13,yRadius:13)
        NSColor(srgbRed:0.17,green:0.15,blue:0.25,alpha:0.96).setFill();pill.fill()
        violet.withAlphaComponent(0.7).setStroke();pill.lineWidth=1;pill.stroke()
        violet.setFill();NSBezierPath(ovalIn:NSRect(x:badge.minX+10,y:badge.minY+10,width:6,height:6)).fill()
        ("NotchPilot" as NSString).draw(at:NSPoint(x:badge.minX+23,y:badge.minY+6),withAttributes:[
            .font:NSFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor(calibratedWhite:0.96,alpha:1)])
        let delivery=NSRect(x:badge.minX+96,y:badge.minY+3,width:22,height:20)
        let chip=NSBezierPath(roundedRect:delivery,xRadius:6,yRadius:6)
        if deliveryMode=="background" { violet.withAlphaComponent(0.75).setFill();chip.fill() }
        else { violet.withAlphaComponent(0.35).setStroke();chip.lineWidth=1;chip.stroke() }
        let icon=deliveryMode=="background" ? "square.on.square" : (kind=="type" || kind=="key") ? "keyboard" : kind.hasPrefix("scroll") ? "arrow.up.and.down" : "cursorarrow"
        symbol(icon,in:delivery.insetBy(dx:5,dy:4),color:.white)
        let target=NSRect(x:badge.minX+122,y:badge.minY+3,width:22,height:20)
        let outline=NSBezierPath(roundedRect:target,xRadius:6,yRadius:6)
        violet.withAlphaComponent(0.5).setStroke();outline.lineWidth=1;outline.stroke()
        let browser=["Google Chrome","Safari","Microsoft Edge","Firefox","Arc","Brave Browser"].contains(appName)
        symbol(browser ? "globe" : "macwindow",in:target.insetBy(dx:4,dy:3),color:NSColor(calibratedWhite:0.94,alpha:1))
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
        if let screen=NSScreen.screens.first(where:{$0.frame.contains(point)}) {
            (window.contentView as? CursorView)?.placeBadge(at:point,on:screen.visibleFrame)
        }
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
