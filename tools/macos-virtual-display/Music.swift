// --music <folder>: plays an album folder in track order, looping, while the
// dashboard is up, and shows it as a "now playing" plate.
import AVFoundation
import AppKit
import SwiftUI

struct TrackInfo {
    var title: String
    var artist: String
    var album: String
    var index: Int
    var count: Int
    var elapsed: Double
    var duration: Double
}

final class MusicPlayer {
    private let tracks: [URL]
    private let player = AVPlayer()
    private var index = 0
    private var endObserver: NSObjectProtocol?
    let cover: NSImage?

    init?(folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        tracks = files
            .filter { ["flac", "mp3", "m4a", "aac", "wav", "aiff", "alac"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !tracks.isEmpty else { return nil }
        cover = ["cover.png", "cover.jpg", "folder.jpg", "folder.png"].lazy
            .compactMap { NSImage(contentsOf: folder.appendingPathComponent($0)) }.first
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
            self.load((self.index + 1) % self.tracks.count)
            self.player.play()
        }
        load(0)
    }

    private func load(_ newIndex: Int) {
        index = newIndex
        player.replaceCurrentItem(with: AVPlayerItem(url: tracks[index]))
    }

    func play() { player.play() }
    func pause() { player.pause() }

    var info: TrackInfo {
        // Bandcamp names files "Artist - Album - NN Title.ext".
        let parts = tracks[index].deletingPathExtension().lastPathComponent.components(separatedBy: " - ")
        var title = parts.last ?? ""
        if let space = title.firstIndex(of: " "), title[..<space].allSatisfy(\.isNumber) {
            title = String(title[title.index(after: space)...])
        }
        let duration = player.currentItem?.duration.seconds ?? 0
        return TrackInfo(title: title, artist: parts.count >= 3 ? parts[0] : "", album: parts.count >= 3 ? parts[1] : "",
                         index: index + 1, count: tracks.count,
                         elapsed: max(player.currentTime().seconds, 0), duration: duration.isFinite ? duration : 0)
    }
}

struct NowPlayingPlate: View {
    let track: TrackInfo
    let cover: NSImage?

    private func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
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
            .overlay(Rectangle().stroke(BB.yellow, lineWidth: 2))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("NOW PLAYING").font(BB.display(13)).foregroundStyle(.black)
                        .padding(.horizontal, 7).background(Parallelogram().fill(BB.yellow))
                    Text(String(format: "%02d / %02d", track.index, track.count)).font(BB.mono(11)).foregroundStyle(BB.ink3)
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
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(BB.glass)
        .overlay(Rectangle().stroke(BB.glassEdge, lineWidth: 1))
    }
}
