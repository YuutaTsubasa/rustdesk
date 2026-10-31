// Prototype: create a HiDPI virtual display with the client's pixel size so a
// RustDesk session fills the client screen without letterboxing.
//
//   virtual-display <pixelWidth> <pixelHeight> [--main] [--mirror]
//
// The display exists while this process runs; Ctrl+C removes it. With --main
// it becomes the main display for this login session only (the arrangement
// reverts when the display goes away). With --mirror the other displays mirror
// it, so no window can open on a screen the client cannot see.
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 3, let pw = UInt(args[1]), let ph = UInt(args[2]), pw % 2 == 0, ph % 2 == 0 else {
    FileHandle.standardError.write("usage: virtual-display <pixelWidth> <pixelHeight> [--main] [--mirror] (even numbers)\n".data(using: .utf8)!)
    exit(64)
}
let makeMain = args.contains("--main")
let mirror = args.contains("--mirror")

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
    print("virtual display terminated by the system")
    exit(1)
}

guard let display = CGVirtualDisplay(descriptor: descriptor) else {
    print("could not create the virtual display")
    exit(1)
}
let settings = CGVirtualDisplaySettings()
settings.hiDPI = 1
// With hiDPI the mode size is in points; the backing store is 2x.
settings.modes = [
    CGVirtualDisplayMode(width: pw / 2, height: ph / 2, refreshRate: 60),
    CGVirtualDisplayMode(width: pw, height: ph, refreshRate: 60),
]
guard display.apply(settings) else {
    print("applySettings failed")
    exit(1)
}
let id = display.displayID
print("created display \(id): \(pw / 2)x\(ph / 2) points, \(pw)x\(ph) pixels")

if makeMain || mirror {
    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    // The main display is the one at origin (0, 0); put the others to its left.
    var x: Int32 = 0
    for other in ids where other != id {
        if mirror {
            CGConfigureDisplayMirrorOfDisplay(config, other, id)
        } else {
            x -= Int32(CGDisplayPixelsWide(other))
            CGConfigureDisplayOrigin(config, other, x, 0)
        }
    }
    CGConfigureDisplayOrigin(config, id, 0, 0)
    let err = CGCompleteDisplayConfiguration(config, .forSession)
    print(err == .success ? "display \(id) is now the main display\(mirror ? ", mirrored by the others" : "")" : "could not configure displays: \(err.rawValue)")
}

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
dispatchMain()
