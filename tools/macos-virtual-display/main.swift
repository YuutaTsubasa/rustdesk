// Prototype: create a HiDPI virtual display with the client's pixel size so a
// RustDesk session fills the client screen without letterboxing.
//
//   virtual-display <pixelWidth> <pixelHeight> [--main] [--mirror]
//                   [--follow-rustdesk] [--pin <bundle id>] [--dashboard]
//                   [--wallpaper <video>]
//
// The display exists while this process runs; Ctrl+C removes it. With --main
// it becomes the main display for this login session only (the arrangement
// reverts when the display goes away). With --mirror the other displays mirror
// it, so no window can open on a screen the client cannot see.
//
// --follow-rustdesk creates the display only while the RustDesk server log
// shows an open connection, and removes it GRACE_SECONDS (default 20) after the
// last one closes, so the physical display gets its own resolution back.
//
// --pin keeps that app's windows filling the physical display and moves every
// other window from the physical display onto the virtual one. It needs the
// Accessibility permission for this binary.
//
// --dashboard shows a full-screen status panel (Dashboard.swift) on the
// physical display while the virtual display exists, and moves other windows
// off it like --pin does. --wallpaper loops a (muted) video behind the panel.
import AppKit
import ApplicationServices
import CoreGraphics

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 3, let pw = UInt(args[1]), let ph = UInt(args[2]), pw % 2 == 0, ph % 2 == 0 else {
    FileHandle.standardError.write("usage: virtual-display <pixelWidth> <pixelHeight> [--main] [--mirror] [--follow-rustdesk] [--pin <bundle id>] [--dashboard] [--wallpaper <video>] (even numbers)\n".data(using: .utf8)!)
    exit(64)
}
let makeMain = args.contains("--main")
let mirror = args.contains("--mirror")
let followRustDesk = args.contains("--follow-rustdesk")
let pinBundleID = args.firstIndex(of: "--pin").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
let showDashboard = args.contains("--dashboard")
let wallpaperURL = args.firstIndex(of: "--wallpaper").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
let graceSeconds = Double(ProcessInfo.processInfo.environment["GRACE_SECONDS"] ?? "") ?? 20

func log(_ message: String) {
    let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("\(stamp) \(message)")
}

func createDisplay() -> CGVirtualDisplay? {
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.queue = DispatchQueue.main
    descriptor.name = "RustDesk Virtual Display"
    descriptor.maxPixelsWide = UInt32(pw)
    descriptor.maxPixelsHigh = UInt32(ph)
    // About 264 ppi, like an iPad Pro, so macOS picks sensible UI scaling.
    descriptor.sizeInMillimeters = CGSize(width: Double(pw) / 264 * 25.4, height: Double(ph) / 264 * 25.4)
    descriptor.vendorID = 0x5244  // "RD"
    descriptor.productID = 0x0001
    descriptor.serialNum = 0x0001
    descriptor.terminationHandler = { _, _ in
        log("virtual display terminated by the system")
        exit(1)
    }

    guard let display = CGVirtualDisplay(descriptor: descriptor) else {
        log("could not create the virtual display")
        return nil
    }
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 1
    // With hiDPI the mode size is in points; the backing store is 2x.
    settings.modes = [
        CGVirtualDisplayMode(width: pw / 2, height: ph / 2, refreshRate: 60),
        CGVirtualDisplayMode(width: pw, height: ph, refreshRate: 60),
    ]
    guard display.apply(settings) else {
        log("applySettings failed")
        return nil
    }
    let id = display.displayID
    log("created display \(id): \(pw / 2)x\(ph / 2) points, \(pw)x\(ph) pixels")

    if makeMain || mirror {
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        // The main display is the one at origin (0, 0); put the others to its left.
        var x: Int32 = 0
        for other in onlineDisplays() where other != id {
            if mirror {
                CGConfigureDisplayMirrorOfDisplay(config, other, id)
            } else {
                // macOS remembers mirroring per display, so clear an earlier --mirror run.
                CGConfigureDisplayMirrorOfDisplay(config, other, kCGNullDirectDisplay)
                x -= Int32(CGDisplayPixelsWide(other))
                CGConfigureDisplayOrigin(config, other, x, 0)
            }
        }
        CGConfigureDisplayOrigin(config, id, 0, 0)
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        log(err == .success ? "display \(id) is now the main display\(mirror ? ", mirrored by the others" : "")" : "could not configure displays: \(err.rawValue)")
    }
    return display
}

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

// "#N Connection opened" / "#N Connection closed" in the RustDesk server log.
func openRustDeskConnections() -> Int {
    let path = NSHomeDirectory() + "/Library/Logs/RustDesk/server/RustDesk_rCURRENT.log"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
    var open = Set<Substring>()
    for line in text.split(separator: "\n") {
        guard let hash = line.firstIndex(of: "#") else { continue }
        let rest = line[line.index(after: hash)...]
        let number = rest.prefix { $0.isNumber }
        guard !number.isEmpty else { continue }
        let after = rest.dropFirst(number.count)
        if after.hasPrefix(" Connection opened") {
            open.insert(number)
        } else if after.hasPrefix(" Connection closed") {
            open.remove(number)
        }
    }
    return open.count
}

func axValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? T
}

func windowFrame(_ window: AXUIElement) -> CGRect? {
    guard let posValue: AXValue = axValue(window, kAXPositionAttribute),
          let sizeValue: AXValue = axValue(window, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(posValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}

func setWindowFrame(_ window: AXUIElement, origin: CGPoint, size: CGSize?) {
    var origin = origin
    if let position = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    }
    if var size = size, let sizeValue = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }
}

func physicalDisplay(besides virtualID: CGDirectDisplayID) -> CGDirectDisplayID? {
    onlineDisplays().first { $0 != virtualID && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
}

func arrangeWindows(virtualID: CGDirectDisplayID, pin: String?) {
    guard let physical = physicalDisplay(besides: virtualID) else { return }
    let physicalBounds = CGDisplayBounds(physical)
    let virtualBounds = CGDisplayBounds(virtualID)
    let menuBar: CGFloat = 25

    if let pin, !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == pin }),
       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pin) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows: [AXUIElement] = axValue(element, kAXWindowsAttribute) else { continue }
        let pinned = app.bundleIdentifier == pin
        for window in windows {
            guard let subrole: String = axValue(window, kAXSubroleAttribute), subrole == kAXStandardWindowSubrole,
                  let frame = windowFrame(window) else { continue }
            if (axValue(window, kAXMinimizedAttribute) as Bool?) == true { continue }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if pinned {
                let target = CGRect(x: physicalBounds.minX, y: physicalBounds.minY + menuBar,
                                    width: physicalBounds.width, height: physicalBounds.height - menuBar)
                if frame.integral != target.integral {
                    setWindowFrame(window, origin: target.origin, size: target.size)
                }
            } else if physicalBounds.contains(center) {
                let size = CGSize(width: min(frame.width, virtualBounds.width), height: min(frame.height, virtualBounds.height - menuBar))
                setWindowFrame(window, origin: CGPoint(x: virtualBounds.minX, y: virtualBounds.minY + menuBar), size: size)
                log("moved a \(app.localizedName ?? "?") window onto the virtual display")
            }
        }
    }
}

var display: CGVirtualDisplay?
var idleSince: Date?
let dashboard = showDashboard ? Dashboard(wallpaper: wallpaperURL) : nil
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if pinBundleID != nil || showDashboard {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(options) {
        log("--pin/--dashboard need Accessibility to move windows: allow this app in System Settings > Privacy & Security > Accessibility")
    }
}

if !followRustDesk {
    display = createDisplay()
    if display == nil { exit(1) }
}

// 1 s so the dashboard clock ticks; reading the RustDesk log is cheap.
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    let connections = openRustDeskConnections()
    if followRustDesk {
        if connections > 0 {
            idleSince = nil
            if display == nil {
                log("RustDesk client connected")
                display = createDisplay()
            }
        } else if display != nil {
            let since = idleSince ?? Date()
            idleSince = since
            if Date().timeIntervalSince(since) >= graceSeconds {
                log("no RustDesk connection for \(Int(graceSeconds))s, removing the virtual display")
                display = nil
                idleSince = nil
            }
        }
    }
    // Without Accessibility, windows on the physical display cannot be moved off,
    // so the panel would hide them (System Settings included): leave it down.
    let trusted = AXIsProcessTrusted()
    dashboard?.update(on: trusted ? display.flatMap { physicalDisplay(besides: $0.displayID) } : nil, connections: connections)
    if let display, pinBundleID != nil || showDashboard, trusted {
        arrangeWindows(virtualID: display.displayID, pin: pinBundleID)
    }
}

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
app.run()
