// --dashboard: a full-screen bluebolt-ui styled panel (clock, system load,
// remote status) on the physical display while a RustDesk client is connected.
// Colours and type follow bluebolt-ui's dark tokens (src/lib/styles/tokens.css).
import AVFoundation
import AppKit
import Darwin
import IOKit.pwr_mgt
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

enum BB {
    static let paper = Color(hex: 0x060b1a)
    static let surface = Color(hex: 0x0d1530)
    static let ink = Color(hex: 0xeef2fa)
    static let ink2 = Color(hex: 0xb4bdcc)
    static let ink3 = Color(hex: 0x8a94a7)
    static let ink4 = Color(hex: 0x4c566a)
    static let line = Color(hex: 0xeef2fa, alpha: 0.16)
    static let blue = Color(hex: 0x183dd6)
    static let blue2 = Color(hex: 0x4d86ff)
    static let sky = Color(hex: 0x3d9bff)
    static let yellow = Color(hex: 0xffd84a)
    static let glass = Color(hex: 0x0d1530, alpha: 0.84)
    static let glassEdge = Color(red: 120 / 255, green: 160 / 255, blue: 1, opacity: 0.35)
    static let red = Color(hex: 0xff5a5a)

    // Anton / Saira Condensed are web fonts; Avenir Next Condensed is the closest built-in face.
    static func display(_ size: CGFloat) -> Font { .custom("AvenirNextCondensed-HeavyItalic", size: size) }
    static func cond(_ size: CGFloat) -> Font { .custom("AvenirNextCondensed-DemiBold", size: size) }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
}

// MARK: - samples

struct CPUSampler {
    private var previous: [UInt32] = []

    mutating func sample() -> Double {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * 4) }
        let ticks = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { previous = ticks }
        guard previous.count == ticks.count else { return 0 }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            for state in 0..<Int(CPU_STATE_MAX) {
                let delta = UInt64(ticks[base + state] &- previous[base + state])
                total += delta
                if state != Int(CPU_STATE_IDLE) { busy += delta }
            }
        }
        return total == 0 ? 0 : Double(busy) / Double(total)
    }
}

/// Bytes in use the way Activity Monitor counts "Memory Used": app + wired + compressed.
func memoryUsed() -> UInt64 {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let pages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
    return pages * UInt64(vm_kernel_page_size)
}

struct NetSampler {
    private var previous: (rx: UInt32, tx: UInt32, at: Date)?

    /// Bytes per second received and sent on the en* interfaces.
    mutating func sample() -> (rx: Double, tx: Double) {
        var rx: UInt32 = 0
        var tx: UInt32 = 0
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return (0, 0) }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            let name = String(cString: entry.pointee.ifa_name)
            if entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"),
               let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                // if_data counters are 32-bit and wrap; the wrapping subtraction below copes.
                rx &+= data.pointee.ifi_ibytes
                tx &+= data.pointee.ifi_obytes
            }
            cursor = entry.pointee.ifa_next
        }
        let now = Date()
        defer { previous = (rx, tx, now) }
        guard let previous else { return (0, 0) }
        let seconds = max(now.timeIntervalSince(previous.at), 0.001)
        return (Double(rx &- previous.rx) / seconds, Double(tx &- previous.tx) / seconds)
    }
}

func tailscaleAddress() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return nil }
    defer { freeifaddrs(head) }
    var cursor = head
    while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        var ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        let host = UInt32(bigEndian: ip.s_addr)
        // Tailscale hands out addresses from the CGNAT range 100.64.0.0/10.
        guard host & 0xffc0_0000 == 0x6440_0000 else { continue }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &ip, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
    return nil
}

/// The last "===== <date> <time> done, N failed =====" line of the newest Kopia log.
func lastBackup() -> (when: String, failed: Int)? {
    let dir = NSHomeDirectory() + "/Data/60_AI/Workspaces/backup-logs"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
    for name in names.filter({ $0.hasSuffix(".log") }).sorted(by: >) {
        guard let text = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n").reversed() where line.hasPrefix("===== ") && line.contains(" done, ") {
            let words = line.split(separator: " ")
            guard words.count >= 6 else { continue }
            return ("\(words[1]) \(words[2].prefix(5))", Int(words[4]) ?? 0)
        }
    }
    return nil
}

// MARK: - model

final class DashboardModel: ObservableObject {
    @Published var now = Date()
    @Published var cpu: [Double] = []
    @Published var memory: (used: UInt64, total: UInt64) = (0, ProcessInfo.processInfo.physicalMemory)
    @Published var netRx: [Double] = []
    @Published var netTx: [Double] = []
    @Published var connections = 0
    @Published var connectedSince: Date?
    @Published var tailscale: String?
    @Published var backup: (when: String, failed: Int)?
    @Published var track: TrackInfo?
    var cover: NSImage?
    var music: MusicPlayer?
    let spectrumFrames = SpectrumFrames()
    var onHide: (() -> Void)?

    private var cpuSampler = CPUSampler()
    private var netSampler = NetSampler()
    private let history = 60

    func refresh(connections: Int) {
        now = Date()
        cpu = Array((cpu + [cpuSampler.sample()]).suffix(history))
        memory.used = memoryUsed()
        let net = netSampler.sample()
        netRx = Array((netRx + [net.rx]).suffix(history))
        netTx = Array((netTx + [net.tx]).suffix(history))
        if connections > 0, self.connections == 0 { connectedSince = now }
        if connections == 0 { connectedSince = nil }
        self.connections = connections
        tailscale = tailscaleAddress()
        backup = lastBackup()
    }
}

// MARK: - views

/// Black header strip with a yellow number tag, as in bluebolt-ui panels.
struct PanelHeader: View {
    let number: String
    let title: String
    let zh: String

    var body: some View {
        HStack(spacing: 10) {
            Text(number)
                .font(BB.display(18))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 8)
                .background(Parallelogram().fill(BB.yellow))
            Text(title).font(BB.display(20)).foregroundStyle(BB.ink)
            Text(zh).font(.system(size: 13, weight: .bold)).foregroundStyle(BB.ink3)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.black)
    }
}

struct Parallelogram: Shape {
    func path(in rect: CGRect) -> Path {
        let lean = rect.height * 0.21  // tan(12°)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + lean, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - lean, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct Panel<Content: View>: View {
    let number: String
    let title: String
    let zh: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(number: number, title: title, zh: zh)
            content.padding(16)
        }
        .background(BB.glass)
        .overlay(Rectangle().stroke(BB.glassEdge, lineWidth: 1))
        .overlay(alignment: .topLeading) { Rectangle().fill(BB.blue2).frame(width: 4).padding(.top, 32) }
    }
}

struct Sparkline: View {
    let values: [Double]
    let ceiling: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let top = max(ceiling, values.max() ?? 0, 0.0001)
            let step = geo.size.width / CGFloat(max(59, values.count - 1))
            let offset = geo.size.width - step * CGFloat(max(values.count - 1, 0))
            let points = values.enumerated().map { index, value in
                CGPoint(x: offset + CGFloat(index) * step, y: geo.size.height * (1 - CGFloat(value / top)))
            }
            ZStack {
                if let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: geo.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { path in path.addLines(points) }.stroke(color, lineWidth: 2)
                }
            }
        }
    }
}

struct Meter: View {
    let label: String
    let zh: String
    let value: String
    let unit: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label).font(BB.cond(14)).foregroundStyle(BB.ink3).tracking(1.5)
                Text(zh).font(.system(size: 11, weight: .bold)).foregroundStyle(BB.ink4)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(BB.display(40)).foregroundStyle(color).monospacedDigit()
                Text(unit).font(BB.cond(16)).foregroundStyle(BB.ink2)
            }
            Text(detail).font(BB.mono(11)).foregroundStyle(BB.ink3)
        }
    }
}

struct StatusRow: View {
    let on: Bool
    let label: String
    let value: String
    var warn = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(warn ? BB.red : on ? BB.yellow : BB.ink4)
                .frame(width: 10, height: 10)
                .shadow(color: (warn ? BB.red : BB.yellow).opacity(on || warn ? 0.8 : 0), radius: 6)
            Text(label).font(BB.cond(17)).foregroundStyle(BB.ink2).frame(width: 96, alignment: .leading)
            Text(value).font(BB.mono(14)).foregroundStyle(on ? BB.ink : BB.ink3).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

func rate(_ bytesPerSecond: Double) -> String {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var value = bytesPerSecond
    var unit = 0
    while value >= 1000, unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
}

func duration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    return s >= 86400 ? "\(s / 86400)d \(s % 86400 / 3600)h" : String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    /// A looping video plays underneath; draw a scrim instead of the opaque background.
    var overVideo = false

    private static let time = formatter("HH:mm")
    private static let seconds = formatter("ss")
    private static let date = formatter("yyyy/MM/dd")
    private static let weekdayEN = formatter("EEE", locale: "en_US")
    private static let weekdayZH = formatter("EEEE", locale: "zh_TW")

    private static func formatter(_ format: String, locale: String = "en_US_POSIX") -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: locale)
        f.dateFormat = format
        return f
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topStrip
                HStack(alignment: .top, spacing: 24) {
                    clock.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    VStack(spacing: 18) {
                        systemPanel
                        remotePanel
                    }
                    .frame(width: 470)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 24)
                bottomStrip
            }
        }
        .foregroundStyle(BB.ink)
    }

    @ViewBuilder private var background: some View {
        if overVideo {
            // Darken the video only where the clock sits (bottom left).
            ZStack {
                Color.black.opacity(0.12)
                LinearGradient(stops: [.init(color: BB.paper.opacity(0.85), location: 0), .init(color: BB.paper.opacity(0.5), location: 0.35),
                                       .init(color: .clear, location: 0.6)], startPoint: .bottom, endPoint: .top)
                LinearGradient(colors: [BB.paper.opacity(0.35), .clear], startPoint: .leading, endPoint: .center)
            }
        } else {
            staticBackground
        }
    }

    private var staticBackground: some View {
        ZStack {
            LinearGradient(colors: [BB.paper, Color(hex: 0x0a1638), BB.paper], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Faceted blue bands, the static stand-in for bluebolt-ui's chrome background.
            GeometryReader { geo in
                Path { path in
                    path.move(to: CGPoint(x: geo.size.width * 0.18, y: geo.size.height))
                    path.addLine(to: CGPoint(x: geo.size.width * 0.52, y: 0))
                    path.addLine(to: CGPoint(x: geo.size.width * 0.66, y: 0))
                    path.addLine(to: CGPoint(x: geo.size.width * 0.32, y: geo.size.height))
                }
                .fill(LinearGradient(colors: [BB.blue.opacity(0.32), BB.blue.opacity(0.04)], startPoint: .bottom, endPoint: .top))
                Path { path in
                    path.move(to: CGPoint(x: geo.size.width * 0.36, y: geo.size.height))
                    path.addLine(to: CGPoint(x: geo.size.width * 0.70, y: 0))
                    path.addLine(to: CGPoint(x: geo.size.width * 0.73, y: 0))
                    path.addLine(to: CGPoint(x: geo.size.width * 0.39, y: geo.size.height))
                }
                .fill(BB.sky.opacity(0.10))
            }
            Text("CHAOTIX")
                .font(BB.display(260))
                .foregroundStyle(.clear)
                .overlay(Text("CHAOTIX").font(BB.display(260)).foregroundStyle(BB.ink.opacity(0.035)))
                .offset(x: -150, y: 210)
        }
    }

    private var topStrip: some View {
        HStack(spacing: 14) {
            Text("01").font(BB.display(16)).foregroundStyle(.black).padding(.horizontal, 8).background(Parallelogram().fill(BB.yellow))
            Text("CHAOTIXMACHINE").font(BB.display(20))
            Text("REMOTE CONSOLE ／ 遠端主控台").font(BB.cond(14)).foregroundStyle(BB.ink3).tracking(1)
            Spacer()
            Button { model.onHide?() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "eye.slash.fill").font(.system(size: 11, weight: .bold))
                    Text("HIDE").font(BB.display(14))
                }
                .foregroundStyle(BB.ink2)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .overlay(Parallelogram().stroke(BB.ink4, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Text(model.connections > 0 ? "ONLINE" : "STANDBY")
                .font(BB.display(15))
                .foregroundStyle(model.connections > 0 ? .black : BB.ink3)
                .padding(.horizontal, 12)
                .background(Parallelogram().fill(model.connections > 0 ? BB.yellow : BB.ink4.opacity(0.4)))
        }
        .padding(.horizontal, 24)
        .frame(height: 40)
        .background(Color.black)
    }

    private var clock: some View {
        // Over the wallpaper video the clock drops to the bottom left so the
        // character in the video stays visible.
        VStack(alignment: .leading, spacing: 0) {
            if let track = model.track {
                NowPlayingPlate(track: track, cover: model.cover, music: model.music).padding(.bottom, overVideo ? 0 : 6)
            }
            if overVideo { Spacer() }
            HStack(spacing: 12) {
                Rectangle().fill(BB.yellow).frame(width: 46, height: 6)
                Text("LOCAL TIME").font(BB.cond(18)).foregroundStyle(overVideo ? BB.ink2 : BB.ink3).tracking(4)
                Text("台北").font(.system(size: 14, weight: .bold)).foregroundStyle(BB.ink4)
            }
            .padding(.top, overVideo ? 0 : 34)
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(Self.time.string(from: model.now))
                    .font(BB.display(overVideo ? 150 : 230))
                    .monospacedDigit()
                    .shadow(color: BB.blue2.opacity(0.55), radius: 24)
                Text(Self.seconds.string(from: model.now))
                    .font(BB.display(overVideo ? 52 : 76))
                    .monospacedDigit()
                    .foregroundStyle(BB.sky)
            }
            .padding(.top, overVideo ? -16 : -24)
            HStack(alignment: .center, spacing: 16) {
                Text(Self.date.string(from: model.now)).font(BB.display(overVideo ? 40 : 52))
                Text(Self.weekdayEN.string(from: model.now).uppercased())
                    .font(BB.display(26))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                    .background(Parallelogram().fill(BB.blue))
                Text(Self.weekdayZH.string(from: model.now)).font(.system(size: 22, weight: .heavy)).foregroundStyle(BB.ink2)
            }
            .padding(.top, -10)
            if let music = model.music {
                if !overVideo { Spacer() }
                SpectrumView(frames: model.spectrumFrames).frame(height: 64).padding(.vertical, 10)
            } else if overVideo {
                Spacer().frame(height: 22)
            } else {
                Spacer()
            }
            HStack(spacing: 4) {
                ForEach(0..<24, id: \.self) { hour in
                    let current = Calendar.current.component(.hour, from: model.now)
                    Rectangle()
                        .fill(hour < current ? BB.blue2 : hour == current ? BB.yellow : BB.line)
                        .frame(height: hour % 6 == 0 ? 18 : 10)
                }
            }
            .frame(height: 18, alignment: .bottom)
            HStack {
                Text("00").font(BB.mono(11))
                Spacer()
                Text("12").font(BB.mono(11))
                Spacer()
                Text("24").font(BB.mono(11))
            }
            .foregroundStyle(BB.ink4)
            .padding(.top, 4)
        }
    }

    private var systemPanel: some View {
        Panel(number: "02", title: "SYSTEM", zh: "系統") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom, spacing: 18) {
                    Meter(label: "CPU", zh: "處理器", value: String(format: "%.0f", (model.cpu.last ?? 0) * 100), unit: "%",
                          detail: "\(ProcessInfo.processInfo.activeProcessorCount) CORES", color: BB.ink)
                        .frame(width: 130, alignment: .leading)
                    Sparkline(values: model.cpu, ceiling: 1, color: BB.blue2).frame(height: 70)
                }
                let used = Double(model.memory.used) / 1_073_741_824
                let total = Double(model.memory.total) / 1_073_741_824
                HStack(alignment: .bottom, spacing: 18) {
                    Meter(label: "MEMORY", zh: "記憶體", value: String(format: "%.1f", used), unit: "GB",
                          detail: String(format: "OF %.0f GB", total), color: BB.ink)
                        .frame(width: 130, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(String(format: "%.0f%%", used / max(total, 1) * 100)).font(BB.display(22)).foregroundStyle(BB.yellow)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(BB.line)
                                Rectangle().fill(LinearGradient(colors: [BB.blue, BB.blue2], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geo.size.width * min(used / max(total, 1), 1))
                            }
                        }
                        .frame(height: 12)
                    }
                    .padding(.bottom, 18)
                }
                HStack(alignment: .bottom, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("NETWORK").font(BB.cond(14)).foregroundStyle(BB.ink3).tracking(1.5)
                            Text("網路").font(.system(size: 11, weight: .bold)).foregroundStyle(BB.ink4)
                        }
                        Text("↓ " + rate(model.netRx.last ?? 0)).font(BB.mono(15)).foregroundStyle(BB.sky)
                        Text("↑ " + rate(model.netTx.last ?? 0)).font(BB.mono(15)).foregroundStyle(BB.yellow)
                    }
                    .frame(width: 130, alignment: .leading)
                    ZStack {
                        let top = max(model.netRx.max() ?? 0, model.netTx.max() ?? 0, 50_000)
                        Sparkline(values: model.netRx, ceiling: top, color: BB.sky)
                        Sparkline(values: model.netTx, ceiling: top, color: BB.yellow)
                    }
                    .frame(height: 56)
                }
            }
        }
    }

    private var remotePanel: some View {
        Panel(number: "03", title: "REMOTE", zh: "遠端") {
            VStack(alignment: .leading, spacing: 12) {
                StatusRow(on: model.connections > 0, label: "iPad",
                          value: model.connectedSince.map { "連線中 · " + duration(model.now.timeIntervalSince($0)) } ?? "未連線")
                // State only: the panel ends up in screen recordings, so keep the address off it.
                StatusRow(on: model.tailscale != nil, label: "Tailscale", value: model.tailscale != nil ? "已連線" : "離線")
                StatusRow(on: model.backup != nil, label: "Backup",
                          value: model.backup.map { $0.failed == 0 ? "\($0.when) 完成" : "\($0.when) 失敗 \($0.failed) 項" } ?? "沒有紀錄",
                          warn: (model.backup?.failed ?? 0) > 0)
                StatusRow(on: true, label: "Uptime", value: duration(ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    private var bottomStrip: some View {
        HStack(spacing: 16) {
            Rectangle().fill(BB.yellow).frame(width: 18, height: 4)
            Text("BLUEBOLT ／ CHAOTIX CONSOLE").font(BB.cond(13)).tracking(2)
            Text("Mac mini · \(ProcessInfo.processInfo.operatingSystemVersionString)").font(BB.mono(11)).foregroundStyle(BB.ink3)
            Spacer()
            HStack(spacing: 3) {
                ForEach(0..<28, id: \.self) { index in
                    Rectangle().fill(BB.ink3).frame(width: index % 3 == 0 ? 3 : 1.5, height: 14)
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 30)
        .background(Color.black)
        .foregroundStyle(BB.ink2)
    }
}

// MARK: - window

/// Borderless windows cannot become key by default; this one can, so Esc hides it.
final class DashboardWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    var onEscape: (() -> Void)?
}

final class Dashboard {
    private let model = DashboardModel()
    private var window: NSWindow?
    private let wallpaper: URL?
    private var player: AVQueuePlayer?
    private var spectrumTimer: Timer?
    /// Keeps the display awake while the panel is shown, so it works as a clock.
    private var noDisplaySleep: IOPMAssertionID?
    private var looper: AVPlayerLooper?
    /// Someone is using the panel: an iPad is connected or it was opened by hand.
    /// Only then does the music play and the display stay awake; otherwise the
    /// panel just sits there as a clock and the display sleeps as usual.
    private var active = false
    let music: MusicPlayer?
    var onHide: (() -> Void)? {
        get { model.onHide }
        set { model.onHide = newValue }
    }
    var isShown: Bool { window?.isVisible == true }

    init(wallpaper: URL?, music: URL?) {
        self.wallpaper = wallpaper
        self.music = music.flatMap { MusicPlayer(folder: $0) }
        model.cover = self.music?.cover
        model.music = self.music
    }

    /// Shows the panel full screen on `displayID`, or hides it when nil.
    /// `focus` takes keyboard focus (for Esc) when the user asked for the panel.
    func update(on displayID: CGDirectDisplayID?, connections: Int, focus: Bool = false) {
        guard let displayID,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID })
        else {
            if window?.isVisible == true {
                window?.orderOut(nil)
                player?.pause()
                spectrumTimer?.invalidate()
                spectrumTimer = nil
            }
            setActive(false)
            return
        }
        model.refresh(connections: connections)
        model.track = music?.info
        let window = self.window ?? makeWindow()
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        if !window.isVisible {
            if focus {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            window.orderFrontRegardless()
            player?.play()
            if let music, spectrumTimer == nil {
                let frames = model.spectrumFrames
                let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in frames.levels = music.spectrum.frame() }
                RunLoop.main.add(timer, forMode: .common)
                spectrumTimer = timer
            }
        }
        setActive(connections > 0 || focus)
    }

    private func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if value {
            music?.resumeForDashboard()
            var assertion = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Dashboard panel is shown" as CFString, &assertion) == kIOReturnSuccess {
                noDisplaySleep = assertion
            }
        } else {
            music?.pauseForDashboard()
            if let assertion = noDisplaySleep {
                IOPMAssertionRelease(assertion)
                noDisplaySleep = nil
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = DashboardWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        // Above the menu bar so the panel covers the whole physical display.
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.onEscape = { [weak self] in self?.model.onHide?() }
        let hosting = NSHostingView(rootView: DashboardView(model: model, overVideo: wallpaper != nil))
        if let wallpaper {
            // AVPlayerLooper keeps a seamless loop; the SwiftUI layer sits on top.
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: wallpaper))
            self.player = player
            let container = NSView()
            container.wantsLayer = true
            let videoLayer = AVPlayerLayer(player: player)
            videoLayer.videoGravity = .resizeAspectFill
            videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            container.layer?.addSublayer(videoLayer)
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            window.contentView = container
            videoLayer.frame = container.bounds
        } else {
            window.contentView = hosting
        }
        self.window = window
        return window
    }
}
