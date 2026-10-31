import AppKit
import AVFoundation

/// Loops a muted video as the desktop picture of one display: a borderless
/// window at the desktop level, under the desktop icons and every app window,
/// that lets clicks through to Finder's desktop.
final class DesktopVideo {
    private let url: URL
    private var window: NSWindow?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?

    init(url: URL) {
        self.url = url
    }

    /// Shows the video on `displayID`, or hides and pauses it when nil.
    func update(on displayID: CGDirectDisplayID?) {
        guard let displayID,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID })
        else {
            if window?.isVisible == true {
                window?.orderOut(nil)
                player?.pause()
            }
            return
        }
        let window = self.window ?? makeWindow()
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        if !window.isVisible {
            window.orderFrontRegardless()
            player?.play()
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
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        self.player = player
        let view = NSView()
        view.wantsLayer = true
        let videoLayer = AVPlayerLayer(player: player)
        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(videoLayer)
        window.contentView = view
        videoLayer.frame = view.bounds
        self.window = window
        return window
    }
}
