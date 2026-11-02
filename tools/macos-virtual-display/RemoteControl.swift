import AppKit
import Network

/// A small web page for the music and the panel, so they can be driven from a
/// phone or the iPad without a keyboard and mouse on this Mac. It listens on
/// 127.0.0.1 only; `tailscale serve` publishes it to the tailnet (which already
/// authenticates the devices, so there is no login), so the macOS firewall
/// needs no exception for this ad-hoc signed app. Peers outside loopback and
/// the Tailscale ranges are refused as a second line.
///
///   GET  /                 the control page
///   GET  /api/state        JSON: track, playlist, volume, panel
///   GET  /cover            album art (PNG)
///   POST /api/<command>    toggle, next, previous, seek?t=, volume?v=,
///                          track?i=, panel?show=0|1
final class RemoteControl {
    private let listener: NWListener
    private let music: MusicPlayer?
    private let isPanelShown: () -> Bool
    private let setPanelShown: (Bool) -> Void
    private lazy var coverPNG: Data? = music?.cover?.tiffRepresentation
        .flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])

    init?(port: UInt16, music: MusicPlayer?, isPanelShown: @escaping () -> Bool, setPanelShown: @escaping (Bool) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        self.music = music
        self.isPanelShown = isPanelShown
        self.setPanelShown = setPanelShown
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { print("remote control: \(error)") }
        }
        listener.start(queue: .main)
    }

    private static func allowed(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let bytes = [UInt8](address.rawValue)
            return bytes == [127, 0, 0, 1] || (bytes[0] == 100 && bytes[1] & 0xc0 == 64)
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            if address == .loopback { return true }
            // IPv4-mapped (::ffff:a.b.c.d), as a dual-stack listener reports IPv4 peers.
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return (bytes[12] == 127 && bytes[13] == 0 && bytes[14] == 0 && bytes[15] == 1) || (bytes[12] == 100 && bytes[13] & 0xc0 == 64)
            }
            return Array(bytes[0..<6]) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        default:
            return false
        }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.allowed(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(connection, to: head)
            } else if done || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, to head: String) {
        let parts = (head.split(separator: "\r\n").first ?? "").split(separator: " ")
        guard parts.count >= 2, let url = URLComponents(string: String(parts[1])) else {
            send(connection, status: "400 Bad Request", type: "text/plain", body: Data("bad request".utf8))
            return
        }
        let method = String(parts[0])
        let query = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        switch (method, url.path) {
        case ("GET", "/"):
            send(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(Self.page.utf8))
        case ("GET", "/api/state"):
            sendState(connection)
        case ("GET", "/cover"):
            if let coverPNG {
                send(connection, status: "200 OK", type: "image/png", body: coverPNG)
            } else {
                send(connection, status: "404 Not Found", type: "text/plain", body: Data("no cover".utf8))
            }
        case ("POST", let path) where path.hasPrefix("/api/"):
            run(String(path.dropFirst(5)), query)
            sendState(connection)
        default:
            send(connection, status: "404 Not Found", type: "text/plain", body: Data("not found".utf8))
        }
    }

    private func run(_ command: String, _ query: [String: String]) {
        switch command {
        case "toggle": music?.toggle()
        case "next": music?.next()
        case "previous": music?.previous()
        case "seek": if let t = Double(query["t"] ?? "") { music?.seek(to: t) }
        case "volume": if let v = Float(query["v"] ?? "") { music?.volume = v }
        case "track": if let i = Int(query["i"] ?? "") { music?.select(i - 1) }
        case "panel": setPanelShown(query["show"] == "1")
        default: break
        }
    }

    private func sendState(_ connection: NWConnection) {
        var state: [String: Any] = ["panel": isPanelShown()]
        if let music {
            let info = music.info
            state["track"] = ["title": info.title, "artist": info.artist, "album": info.album, "index": info.index,
                              "count": info.count, "elapsed": info.elapsed, "duration": info.duration,
                              "playing": info.playing, "volume": info.volume]
            state["titles"] = music.titles
        }
        let body = (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
        send(connection, status: "200 OK", type: "application/json", body: body)
    }

    private func send(_ connection: NWConnection, status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // The bluebolt-ui dark palette, as on the panel.
    private static let page = """
    <!doctype html>
    <html lang="zh-Hant">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="theme-color" content="#0b0f1a">
    <title>ChaotixMachine</title>
    <style>
      :root { --bg:#0b0f1a; --card:#141a2b; --line:#26304a; --ink:#f3f6fd; --ink2:#a9b4cc; --blue:#2f5bff; --yellow:#ffd21f; }
      * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
      body { margin:0; background:var(--bg); color:var(--ink); font:500 16px -apple-system, "PingFang TC", sans-serif;
             padding:max(16px, env(safe-area-inset-top)) 16px max(24px, env(safe-area-inset-bottom)); }
      main { max-width:480px; margin:0 auto; }
      header { display:flex; align-items:center; justify-content:space-between; margin-bottom:16px; }
      h1 { margin:0; font:italic 900 22px "Avenir Next Condensed", sans-serif; letter-spacing:.04em; }
      h1 span { color:var(--yellow); }
      .card { background:var(--card); border:1px solid var(--line); border-radius:18px; padding:16px; margin-bottom:14px; }
      .now { display:flex; gap:14px; align-items:center; }
      .now img { width:96px; height:96px; border-radius:12px; object-fit:cover; background:#000; flex:none; }
      .title { font-size:19px; font-weight:700; line-height:1.25; }
      .sub { color:var(--ink2); font-size:14px; margin-top:4px; }
      .bar { height:28px; display:flex; align-items:center; margin-top:14px; cursor:pointer; }
      .bar div { height:6px; width:100%; border-radius:3px; background:var(--line); overflow:hidden; }
      .bar i { display:block; height:100%; background:var(--blue); width:0; }
      .times { display:flex; justify-content:space-between; color:var(--ink2); font-size:13px; font-variant-numeric:tabular-nums; }
      .controls { display:flex; justify-content:center; gap:22px; margin:12px 0 4px; }
      button { font:inherit; color:inherit; background:none; border:0; cursor:pointer; }
      .controls button { width:60px; height:60px; border-radius:30px; font-size:26px; background:var(--line); }
      .controls .play { width:76px; height:76px; border-radius:38px; background:var(--yellow); color:#0b0f1a; font-size:32px; }
      .vol { display:flex; align-items:center; gap:12px; margin-top:12px; color:var(--ink2); }
      input[type=range] { flex:1; accent-color:var(--blue); height:28px; }
      .panel { padding:10px 16px; border-radius:20px; border:1px solid var(--line); font-weight:700; font-size:14px; }
      .panel.on { background:var(--blue); border-color:var(--blue); }
      ol { list-style:none; margin:0; padding:0; }
      li { padding:12px 4px; border-bottom:1px solid var(--line); display:flex; gap:12px; cursor:pointer; }
      li:last-child { border-bottom:0; }
      li b { color:var(--ink2); width:24px; text-align:right; font-variant-numeric:tabular-nums; }
      li.cur { color:var(--yellow); }
      li.cur b { color:var(--yellow); }
      .off { color:var(--ink2); text-align:center; padding:24px 0; }
    </style>
    </head>
    <body>
    <main>
      <header><h1>CHAOTIX<span>MACHINE</span></h1><button class="panel" id="panel">面板</button></header>
      <section class="card" id="player">
        <div class="now"><img id="cover" src="/cover" alt=""><div><div class="title" id="title">—</div><div class="sub" id="sub"></div></div></div>
        <div class="bar" id="bar"><div><i id="fill"></i></div></div>
        <div class="times"><span id="elapsed">0:00</span><span id="duration">0:00</span></div>
        <div class="controls">
          <button id="prev" aria-label="上一首">⏮</button>
          <button class="play" id="toggle" aria-label="播放／暫停">▶</button>
          <button id="next" aria-label="下一首">⏭</button>
        </div>
        <div class="vol"><span>音量</span><input type="range" id="volume" min="0" max="1" step="0.01"></div>
      </section>
      <section class="card"><ol id="list"></ol></section>
    </main>
    <script>
      const $ = id => document.getElementById(id);
      const fmt = s => { s = Math.max(0, Math.floor(s)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
      let state = null, dragging = false, listKey = '';
      async function call(cmd, params) {
        const q = params ? '?' + new URLSearchParams(params) : '';
        render(await (await fetch('/api/' + cmd + q, { method: 'POST' })).json());
      }
      function render(s) {
        state = s;
        $('panel').classList.toggle('on', s.panel);
        $('panel').textContent = s.panel ? '面板：開' : '面板：關';
        const t = s.track;
        if (!t) { $('player').innerHTML = '<div class="off">這台沒有開音樂</div>'; return; }
        $('title').textContent = t.title;
        $('sub').textContent = [t.artist, t.album].filter(Boolean).join(' · ') + `  ${t.index}/${t.count}`;
        $('fill').style.width = (t.duration ? t.elapsed / t.duration * 100 : 0) + '%';
        $('elapsed').textContent = fmt(t.elapsed);
        $('duration').textContent = fmt(t.duration);
        $('toggle').textContent = t.playing ? '❚❚' : '▶';
        if (!dragging) $('volume').value = t.volume;
        const key = s.titles.join('\\n');
        if (key !== listKey) {
          listKey = key;
          $('list').innerHTML = s.titles.map((n, i) => `<li data-i="${i + 1}"><b>${i + 1}</b><span></span></li>`).join('');
          $('list').querySelectorAll('li span').forEach((el, i) => el.textContent = s.titles[i]);
        }
        $('list').querySelectorAll('li').forEach(li => li.classList.toggle('cur', Number(li.dataset.i) === t.index));
      }
      async function poll() {
        try { render(await (await fetch('/api/state')).json()); } catch {}
      }
      $('toggle').onclick = () => call('toggle');
      $('next').onclick = () => call('next');
      $('prev').onclick = () => call('previous');
      $('panel').onclick = () => call('panel', { show: state && state.panel ? 0 : 1 });
      $('bar').onclick = e => {
        if (!state || !state.track) return;
        const r = e.currentTarget.getBoundingClientRect();
        call('seek', { t: (e.clientX - r.left) / r.width * state.track.duration });
      };
      $('volume').oninput = e => { dragging = true; call('volume', { v: e.target.value }); };
      $('volume').onchange = () => { dragging = false; };
      $('list').onclick = e => { const li = e.target.closest('li'); if (li) call('track', { i: li.dataset.i }); };
      poll();
      setInterval(poll, 1000);
    </script>
    </body>
    </html>
    """
}
