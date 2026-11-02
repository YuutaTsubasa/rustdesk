// --music <folder>: plays an album folder in track order, looping, while the
// dashboard is up, shows it as a "now playing" plate with a live spectrum,
// and registers with macOS Now Playing (Control Center, media keys) so it can
// be paused, skipped or resumed from the iPad through the menu bar.
import Accelerate
import AVFoundation
import AppKit
import MediaPlayer
import SwiftUI

struct TrackInfo {
    var title: String
    var artist: String
    var album: String
    var index: Int
    var count: Int
    var elapsed: Double
    var duration: Double
    var playing: Bool
    var volume: Float
}

/// Spectrum bands written by the audio tap thread and read by the view.
final class Spectrum: @unchecked Sendable {
    static let bands = 48
    private let lock = NSLock()
    private var target = [Float](repeating: 0, count: bands)
    private var shown = [Float](repeating: 0, count: bands)
    private var peak: Float = 1e-6

    private let log2n: vDSP_Length = 11  // 2048-point FFT
    private lazy var setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    private lazy var window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 1 << Int(log2n), isHalfWindow: false)

    func analyze(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], let setup else { return }
        let n = 1 << Int(log2n)
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        // Newest n samples, zero-padded when the buffer is shorter.
        var samples = [Float](repeating: 0, count: n)
        let take = min(n, count)
        for i in 0..<take { samples[i] = channel[count - take + i] }
        vDSP.multiply(samples, window, result: &samples)

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBufferPointer { sp in
                    sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        // Log-spaced bands from 40 Hz to 16 kHz.
        let rate = Float(buffer.format.sampleRate)
        let binHz = rate / Float(n)
        var levels = [Float](repeating: 0, count: Self.bands)
        for band in 0..<Self.bands {
            let lo = 40 * pow(400, Float(band) / Float(Self.bands))
            let hi = 40 * pow(400, Float(band + 1) / Float(Self.bands))
            let first = max(1, Int(lo / binHz))
            let last = max(first + 1, min(n / 2, Int(hi / binHz)))
            levels[band] = magnitudes[first..<last].max() ?? 0
        }
        // Normalise against a slowly decaying peak so quiet and loud tracks both fill the height.
        let loudest = levels.max() ?? 0
        lock.lock()
        peak = max(peak * 0.985, loudest, 1e-6)
        target = levels.map { sqrt(min($0 / peak, 1)) }
        lock.unlock()
    }

    func silence() {
        lock.lock()
        target = [Float](repeating: 0, count: Self.bands)
        lock.unlock()
    }

    /// Eases the shown levels toward the latest analysis; call once per frame.
    func frame() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<Self.bands {
            let rate: Float = target[i] > shown[i] ? 0.5 : 0.12  // fast attack, slow release
            shown[i] += (target[i] - shown[i]) * rate
        }
        return shown
    }
}

final class MusicPlayer {
    private let tracks: [URL]
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    /// The spectrum taps this mixer, before the volume set on the main mixer.
    private let tapMixer = AVAudioMixerNode()
    private var file: AVAudioFile?
    private var index = 0
    private var startFrame: AVAudioFramePosition = 0
    private var pausedAt: Double = 0
    /// Bumped on every reschedule so a stale completion callback does nothing.
    private var generation = 0
    private(set) var playing = false
    /// Paused by the user (Now Playing, media keys, the plate): stay paused on reconnect.
    private var userPaused = false
    let cover: NSImage?
    let spectrum = Spectrum()

    init?(folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        tracks = files
            .filter { ["flac", "mp3", "m4a", "aac", "wav", "aiff", "caf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !tracks.isEmpty else { return nil }
        cover = ["cover.png", "cover.jpg", "folder.jpg", "folder.png"].lazy
            .compactMap { NSImage(contentsOf: folder.appendingPathComponent($0)) }.first

        engine.attach(node)
        engine.attach(tapMixer)
        engine.connect(tapMixer, to: engine.mainMixerNode, format: nil)
        let spectrum = spectrum
        tapMixer.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in spectrum.analyze(buffer) }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // The output device changed (e.g. speakers unplugged); pick up where we were.
            guard let self, self.playing else { return }
            self.seek(to: self.elapsed)
        }
        load(0, from: 0)
        setUpRemoteCommands()
    }

    // MARK: playback

    private func load(_ newIndex: Int, from seconds: Double) {
        generation += 1
        node.stop()
        index = (newIndex + tracks.count) % tracks.count
        guard let file = try? AVAudioFile(forReading: tracks[index]) else {
            print("could not open \(tracks[index].lastPathComponent)")
            return
        }
        self.file = file
        if engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty || node.outputFormat(forBus: 0) != file.processingFormat {
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: tapMixer, format: file.processingFormat)
        }
        let rate = file.processingFormat.sampleRate
        startFrame = min(AVAudioFramePosition(seconds * rate), max(file.length - 1, 0))
        pausedAt = seconds
        let generation = generation
        node.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(file.length - startFrame), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.load(self.index + 1, from: 0)
                if self.playing { self.startNode() }
                self.publishNowPlaying()
            }
        }
    }

    private func startNode() {
        if !engine.isRunning {
            do { try engine.start() } catch { print("audio engine failed to start: \(error)") }
        }
        node.play()
    }

    /// Called when the dashboard appears; respects an explicit pause.
    func resumeForDashboard() {
        if !userPaused { play() }
    }

    /// Called when the dashboard hides.
    func pauseForDashboard() {
        pauseNode()
    }

    func play() {
        userPaused = false
        guard !playing else { return }
        playing = true
        startNode()
        publishNowPlaying()
    }

    func pause() {
        userPaused = true
        pauseNode()
    }

    private func pauseNode() {
        guard playing else { return }
        pausedAt = elapsed
        playing = false
        node.pause()
        // Release the output device too, or the engine keeps playing silence.
        engine.pause()
        spectrum.silence()
        publishNowPlaying()
    }

    func toggle() { playing ? pause() : play() }

    func next() {
        load(index + 1, from: 0)
        if playing { startNode() }
        publishNowPlaying()
    }

    /// Back to the start of the track, or to the previous one within the first 3 seconds.
    func previous() {
        load(elapsed > 3 ? index : index - 1, from: 0)
        if playing { startNode() }
        publishNowPlaying()
    }

    /// Titles in play order, parsed like `info.title`.
    var titles: [String] {
        tracks.map { url in
            let name = url.deletingPathExtension().lastPathComponent.components(separatedBy: " - ").last ?? ""
            guard let space = name.firstIndex(of: " "), name[..<space].allSatisfy(\.isNumber) else { return name }
            return String(name[name.index(after: space)...])
        }
    }

    func select(_ track: Int) {
        guard tracks.indices.contains(track) else { return }
        load(track, from: 0)
        if playing { startNode() } else { play() }
        publishNowPlaying()
    }

    func seek(to seconds: Double) {
        load(index, from: max(seconds, 0))
        if playing { startNode() }
        publishNowPlaying()
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = min(max(newValue, 0), 1) }
    }

    private var elapsed: Double {
        guard playing, let file, let renderTime = node.lastRenderTime, let time = node.playerTime(forNodeTime: renderTime) else { return pausedAt }
        return Double(startFrame + time.sampleTime) / file.processingFormat.sampleRate
    }

    private var duration: Double {
        guard let file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var info: TrackInfo {
        // Bandcamp names files "Artist - Album - NN Title.ext".
        let parts = tracks[index].deletingPathExtension().lastPathComponent.components(separatedBy: " - ")
        var title = parts.last ?? ""
        if let space = title.firstIndex(of: " "), title[..<space].allSatisfy(\.isNumber) {
            title = String(title[title.index(after: space)...])
        }
        return TrackInfo(title: title, artist: parts.count >= 3 ? parts[0] : "", album: parts.count >= 3 ? parts[1] : "",
                         index: index + 1, count: tracks.count, elapsed: min(elapsed, duration), duration: duration,
                         playing: playing, volume: volume)
    }

    // MARK: Now Playing

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func publishNowPlaying() {
        let info = self.info
        var now: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPMediaItemPropertyAlbumTitle: info.album,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPMediaItemPropertyAlbumTrackNumber: info.index,
            MPMediaItemPropertyAlbumTrackCount: info.count,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.playing ? 1.0 : 0.0,
        ]
        if let cover {
            now[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cover.size) { _ in cover }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = now
        MPNowPlayingInfoCenter.default().playbackState = info.playing ? .playing : .paused
    }
}

// MARK: - views

/// Levels for the view, pushed at 30 fps by Dashboard while the panel is up.
/// (A TimelineView(.animation) never ticked in this borderless window, which
/// left the spectrum flat.)
final class SpectrumFrames: ObservableObject {
    @Published var levels = [Float](repeating: 0, count: Spectrum.bands)
}

struct SpectrumView: View {
    @ObservedObject var frames: SpectrumFrames

    var body: some View {
        Canvas { context, size in
            let levels = frames.levels
            let step = size.width / CGFloat(levels.count)
            let barWidth = max(step * 0.45, 2)
            var points: [CGPoint] = []
            for (i, level) in levels.enumerated() {
                let height = max(CGFloat(level) * size.height, 2)
                let x = CGFloat(i) * step + step / 2
                points.append(CGPoint(x: x, y: size.height - height))
                let bar = CGRect(x: x - barWidth / 2, y: size.height - height, width: barWidth, height: height)
                context.fill(Path(bar), with: .linearGradient(Gradient(colors: [BB.sky.opacity(0.9), BB.blue.opacity(0.25)]),
                                                              startPoint: CGPoint(x: 0, y: bar.minY), endPoint: CGPoint(x: 0, y: size.height)))
            }
            // A smooth line over the bar tops, with a glow.
            var line = Path()
            if let first = points.first {
                line.move(to: first)
                for i in 1..<points.count {
                    let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
                    line.addQuadCurve(to: mid, control: points[i - 1])
                }
                if let last = points.last { line.addLine(to: last) }
            }
            var glow = context
            glow.addFilter(.blur(radius: 6))
            glow.stroke(line, with: .color(BB.sky), lineWidth: 4)
            context.stroke(line, with: .color(BB.yellow), lineWidth: 1.5)
        }
    }
}

struct NowPlayingPlate: View {
    let track: TrackInfo
    let cover: NSImage?
    let music: MusicPlayer?

    private func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func control(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .heavy)).frame(width: 24, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(BB.ink)
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let cover {
                    Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                } else {
                    BB.blue
                }
            }
            .frame(width: 76, height: 76)
            .clipped()
            .overlay(Rectangle().stroke(track.playing ? BB.yellow : BB.ink4, lineWidth: 2))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(track.playing ? "NOW PLAYING" : "PAUSED").font(BB.display(13)).foregroundStyle(.black)
                        .padding(.horizontal, 7).background(Parallelogram().fill(track.playing ? BB.yellow : BB.ink3))
                        .fixedSize()
                    Text(String(format: "%02d / %02d", track.index, track.count)).font(BB.mono(11)).foregroundStyle(BB.ink3).fixedSize()
                }
                Text(track.title).font(BB.display(22)).lineLimit(1)
                Text("\(track.artist) · \(track.album)").font(BB.cond(13)).foregroundStyle(BB.ink2).lineLimit(1)
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(BB.line)
                            Rectangle().fill(BB.sky)
                                .frame(width: geo.size.width * (track.duration > 0 ? min(track.elapsed / track.duration, 1) : 0))
                        }
                    }
                    .frame(height: 4)
                    Text("\(clock(track.elapsed)) / \(clock(track.duration))").font(BB.mono(10)).foregroundStyle(BB.ink3)
                }
                if let music {
                    HStack(spacing: 4) {
                        control("backward.end.fill") { music.previous() }
                        control(track.playing ? "pause.fill" : "play.fill") { music.toggle() }
                        control("forward.end.fill") { music.next() }
                        Spacer().frame(width: 6)
                        control("speaker.minus.fill") { music.volume -= 0.1 }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(BB.line)
                                Rectangle().fill(BB.yellow).frame(width: geo.size.width * CGFloat(track.volume))
                            }
                        }
                        .frame(height: 3)
                        control("speaker.plus.fill") { music.volume += 0.1 }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(BB.glass)
        .overlay(Rectangle().stroke(BB.glassEdge, lineWidth: 1))
    }
}
