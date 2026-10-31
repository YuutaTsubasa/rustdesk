import AppKit
import AVFoundation

/// Loops a muted video as the desktop picture of a set of displays: one
/// borderless window per display, under the desktop icons and every app
/// window, that lets clicks through to Finder's desktop. All windows show the
/// same player, and it pauses while the displays sleep.
final class DesktopVideo {
    private let player = AVQueuePlayer()
    private let looper: AVPlayerLooper
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var asleep = false

    init(url: URL) {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true
            self?.player.pause()
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            asleep = false
            if !windows.isEmpty { player.play() }
        }
    }

    /// Shows the video on exactly `displayIDs`; with none it pauses.
    func update(on displayIDs: [CGDirectDisplayID]) {
        let screens = Dictionary(NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { ($0.uint32Value, screen) }
        }, uniquingKeysWith: { first, _ in first })
        for (id, window) in windows where !displayIDs.contains(id) || screens[id] == nil {
            window.orderOut(nil)
            windows[id] = nil
        }
        for id in displayIDs {
            guard let screen = screens[id] else { continue }
            let window = windows[id] ?? makeWindow()
            if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            if !window.isVisible { window.orderFrontRegardless() }
            windows[id] = window
        }
        if windows.isEmpty {
            player.pause()
        } else if !asleep, player.rate == 0 {
            player.play()
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        // Just under the desktop icons: the Dock draws the wallpaper on a couple
        // of levels above kCGDesktopWindowLevel, which would cover the video.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        let videoLayer = AVPlayerLayer(player: player)
        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(videoLayer)
        window.contentView = view
        videoLayer.frame = view.bounds
        return window
    }
}
