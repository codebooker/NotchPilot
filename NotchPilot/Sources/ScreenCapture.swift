import AppKit
import ScreenCaptureKit

enum PilotScreenCapture {
    static func save(to path:String) async throws {
        let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
        guard let display=content.displays.first(where:{$0.displayID==CGMainDisplayID()}) else {
            throw NSError(domain:"NotchPilot capture",code:1,userInfo:[NSLocalizedDescriptionKey:"The main display is unavailable."])
        }
        let excluded=content.applications.filter { $0.bundleIdentifier=="local.notchpilot.app" }
        guard !excluded.isEmpty else {
            throw NSError(domain:"NotchPilot capture",code:3,userInfo:[NSLocalizedDescriptionKey:"Could not exclude NotchPilot from the screen observation. Please retry."])
        }
        let filter=SCContentFilter(display:display,excludingApplications:excluded,exceptingWindows:[])
        let config=SCStreamConfiguration()
        config.width=CGDisplayPixelsWide(display.displayID);config.height=CGDisplayPixelsHigh(display.displayID)
        config.showsCursor=false;config.capturesAudio=false
        let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
        guard let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {
            throw NSError(domain:"NotchPilot capture",code:2)
        }
        try data.write(to:URL(fileURLWithPath:path),options:.atomic)
    }
}
