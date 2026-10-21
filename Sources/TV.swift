import AppKit
import SwiftUI

struct TVApp: Identifiable, Equatable {
    let id: String
    let title: String
    let color: Color
    var icon: NSImage?
}

struct TVInput: Identifiable, Equatable {
    let id: String      // e.g. HDMI_1
    let label: String
    let appId: String
    let connected: Bool
}

struct SentVideo: Identifiable, Equatable {
    let id: String      // YouTube video id
    var title: String
    var channel: String
    var thumbnail: NSImage?
}

/// Everything the app knows about the TV, and every command it can send.
/// Talks SSAP (the protocol LG's own phone app uses) over wss://TV:3001. No Developer Mode needed.
@MainActor
final class TV: NSObject, ObservableObject, URLSessionDelegate {
    enum Status: Equatable { case idle, searching, connecting, pairing, online, offline }

    @Published var saved: [SavedTV] = Library.load()
    @Published var currentID: String? = UserDefaults.standard.string(forKey: "currentTV")
    @Published var found: [Discovery.Found] = []
    @Published var status = Status.idle
    @Published var volume = 0.0
    @Published var muted = false
    @Published var foreground = ""
    @Published var keyboardOpen = false
    @Published var apps: [TVApp] = []
    @Published var inputs: [TVInput] = []
    @Published var frame: CGImage?
    @Published var frameTime: Date?
    @Published var capturing = false
    @Published var notice: String?
    @Published var sent: [SentVideo] = []
    @Published var sleepAt: Date?
    var draggingVolume = false

    var current: SavedTV? { saved.first { $0.id == currentID } }
    var name: String { current?.name ?? "No TV" }

    private var session: URLSession!
    private var ws: URLSessionWebSocketTask?
    private var pointer: URLSessionWebSocketTask?
    private var replies: [String: (JSON) -> Void] = [:]
    private var subscriptions: [String: (JSON) -> Void] = [:]
    private var counter = 0
    private var retryDelay = 2.0
    private var volumeTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    nonisolated(unsafe) private var trustedHost = ""

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        if currentID == nil { currentID = saved.first?.id }
    }

    // The TV signs its certificate with LG's own CA: trust it for the selected TV only.
    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, space.host == trustedHost, let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: Finding and pairing TVs

    func discover() {
        status = current == nil ? .searching : status
        Task {
            let tvs = await Discovery.search()
            found = tvs
            // Refresh names/addresses of TVs we already know (DHCP can move them).
            for tv in tvs {
                if let i = saved.firstIndex(where: { $0.id == tv.id || $0.host == tv.host }) {
                    saved[i].name = tv.name
                    saved[i].host = tv.host
                    if saved[i].id == saved[i].host { saved[i].id = tv.id; if currentID == tv.host { currentID = tv.id } }
                }
            }
            Library.save(saved)
            if status == .searching { status = .idle }
        }
    }

    func choose(_ tv: Discovery.Found) {
        if !saved.contains(where: { $0.id == tv.id }) {
            saved.append(SavedTV(id: tv.id, name: tv.name, host: tv.host, clientKey: nil))
            Library.save(saved)
        }
        select(tv.id)
    }

    func select(_ id: String) {
        guard id != currentID || status != .online else { return }
        disconnect()
        currentID = id
        UserDefaults.standard.set(id, forKey: "currentTV")
        connect()
    }

    func forget(_ id: String) {
        if id == currentID { disconnect(); currentID = nil; status = .idle }
        saved.removeAll { $0.id == id }
        Library.save(saved)
    }

    // MARK: Connection

    func connect() {
        guard ws == nil, let tv = current else { return }
        status = .connecting
        trustedHost = tv.host
        let task = session.webSocketTask(with: URL(string: "wss://\(tv.host):3001")!)
        ws = task
        task.resume()
        listen(task)
        var payload: JSON = ["forcePairing": false, "pairingType": "PROMPT",
                             "manifest": ["manifestVersion": 1, "appVersion": "1.1", "permissions": permissions]]
        if let key = tv.clientKey { payload["client-key"] = key }
        send(task, ["type": "register", "id": "register", "payload": payload])
    }

    func wake() {
        if status == .offline || status == .idle { retryDelay = 2; connect() }
    }

    private func disconnect() {
        let old = ws
        ws = nil
        old?.cancel(with: .goingAway, reason: nil)
        pointer?.cancel(with: .goingAway, reason: nil)
        pointer = nil
        replies.values.forEach { $0([:]) }
        replies.removeAll()
        subscriptions.removeAll()
        apps = []
        inputs = []
        frame = nil
    }

    private func send(_ task: URLSessionWebSocketTask, _ message: JSON) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, task === self.ws else { return }
                switch result {
                case .failure: self.dropped()
                case .success(let message):
                    if case .string(let text) = message,
                       let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON {
                        self.handle(json)
                    }
                    self.listen(task)
                }
            }
        }
    }

    private func handle(_ msg: JSON) {
        let id = msg["id"] as? String ?? ""
        let payload = msg["payload"] as? JSON ?? [:]
        switch msg["type"] as? String {
        case "response" where id == "register":
            if payload["pairingType"] as? String == "PROMPT" { status = .pairing }
        case "registered":
            if let key = payload["client-key"] as? String, let i = saved.firstIndex(where: { $0.id == currentID }) {
                saved[i].clientKey = key
                Library.save(saved)
            }
            retryDelay = 2
            status = .online
            Task { await self.ready() }
        case "error" where id == "register":
            show("The TV said no. Accept the prompt on the TV to pair.")
            dropped()
        default:
            if let reply = replies.removeValue(forKey: id) { reply(payload) }
            else { subscriptions[id]?(payload) }
        }
    }

    private func dropped() {
        disconnect()
        status = .offline
        // The TV sleeps, reboots and changes networks: retry with back-off, capped at 30 s.
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if self.ws == nil, self.current != nil { self.connect() }
        }
    }

    @discardableResult
    func call(_ uri: String, _ payload: JSON = [:]) async -> JSON {
        guard let ws else { return [:] }
        counter += 1
        let id = "r\(counter)"
        return await withCheckedContinuation { done in
            replies[id] = { done.resume(returning: $0) }
            send(ws, ["type": "request", "id": id, "uri": uri, "payload": payload])
            Task {
                try? await Task.sleep(for: .seconds(8))
                self.replies.removeValue(forKey: id)?([:])
            }
        }
    }

    private func subscribe(_ uri: String, _ handler: @escaping (JSON) -> Void) {
        guard let ws else { return }
        counter += 1
        let id = "s\(counter)"
        subscriptions[id] = handler
        send(ws, ["type": "subscribe", "id": id, "uri": uri, "payload": [:]])
    }

    private func ready() async {
        subscribe("ssap://audio/getVolume") { [weak self] p in
            guard let self, !self.draggingVolume else { return }
            // Firmware answers either flat {volume, muted} or nested {volumeStatus: {volume, muteStatus}}.
            let s = p["volumeStatus"] as? JSON ?? p
            if let v = s["volume"] as? Int { self.volume = Double(v) }
            if let m = (s["muteStatus"] ?? s["muted"] ?? p["mute"]) as? Bool { self.muted = m }
        }
        subscribe("ssap://com.webos.applicationManager/getForegroundAppInfo") { [weak self] p in
            guard let self, let app = p["appId"] as? String else { return }
            self.foreground = app
        }
        subscribe("ssap://com.webos.service.ime/registerRemoteKeyboard") { [weak self] p in
            if let widget = p["currentWidget"] as? JSON { self?.keyboardOpen = widget["focus"] as? Bool ?? false }
        }
        let socket = await call("ssap://com.webos.service.networkinput/getPointerInputSocket")
        if let path = socket["socketPath"] as? String, let url = URL(string: path) {
            pointer = session.webSocketTask(with: url)
            pointer?.resume()
        }
        await loadApps()
        if let i = saved.firstIndex(where: { $0.id == currentID }), saved[i].mac == nil, let mac = macAddress(of: saved[i].host) {
            saved[i].mac = mac
            Library.save(saved)
        }
    }

    private func loadApps() async {
        let points = await call("ssap://com.webos.applicationManager/listLaunchPoints")["launchPoints"] as? [JSON] ?? []
        apps = points.compactMap { p in
            guard let id = p["id"] as? String, p["hidden"] as? Bool != true, id != "com.palmdts.devmode" else { return nil }
            return TVApp(id: id, title: p["title"] as? String ?? id, color: Color(hex: p["iconColor"] as? String ?? "#333333"))
        }
        let devices = await call("ssap://tv/getExternalInputList")["devices"] as? [JSON] ?? []
        inputs = devices.compactMap { d in
            guard let id = d["id"] as? String, let appId = d["appId"] as? String else { return nil }
            return TVInput(id: id, label: d["label"] as? String ?? id, appId: appId, connected: d["connected"] as? Bool ?? false)
        }
        for p in points {
            guard let id = p["id"] as? String, let link = (p["largeIcon"] ?? p["icon"]) as? String,
                  let url = URL(string: link), let (data, _) = try? await session.data(from: url),
                  let i = apps.firstIndex(where: { $0.id == id }) else { continue }
            apps[i].icon = NSImage(data: data)
        }
    }

    // MARK: Screen capture, on demand only

    /// Takes one screenshot of the TV (960x540).
    func capture() {
        guard status == .online, !capturing else { return }
        capturing = true
        Task {
            defer { capturing = false }
            let shot = await call("ssap://tv/executeOneShot", ["path": "/tmp/capture.jpg", "method": "DISPLAY", "format": "JPG"])
            guard let link = shot["imageUri"] as? String, let url = URL(string: link),
                  let (data, _) = try? await session.data(from: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { show("Couldn't capture the screen"); return }
            withAnimation(.easeInOut(duration: 0.2)) { frame = image; frameTime = Date() }
        }
    }

    // MARK: Commands

    func press(_ button: String) {
        guard let pointer else { show("Not connected"); return }
        pointer.send(.string("type:button\nname:\(button)\n\n")) { _ in }
    }

    func launch(_ id: String) {
        Task { await call("ssap://system.launcher/launch", ["id": id]) }
    }

    func setVolume(_ value: Double) {
        volume = value
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(80))  // debounce slider drags
            guard !Task.isCancelled else { return }
            await call("ssap://audio/setVolume", ["volume": Int(value.rounded())])
        }
    }

    func toggleMute() {
        muted.toggle()
        Task { await call("ssap://audio/setMute", ["mute": muted]) }
    }

    func powerOff() {
        Task { await call("ssap://system/turnOff") }
        show("Turning the TV off")
    }

    /// Turns the TV on with Wake-on-LAN. Needs "Turn on via Wi-Fi" in the TV's settings.
    func powerOn() {
        guard let mac = current?.mac else { show("Connect once while the TV is on, so the app learns its address"); return }
        wakeOnLAN(mac: mac)
        show("Waking the TV…")
        Task {
            try? await Task.sleep(for: .seconds(4))
            self.wake()
        }
    }

    /// Types into the text box open on the TV (LG's keyboard only: YouTube uses its own).
    func type(_ text: String, replace: Bool) {
        Task { await call("ssap://com.webos.service.ime/insertText", ["text": text, "replace": replace]) }
    }

    func deleteBackward() {
        Task { await call("ssap://com.webos.service.ime/deleteCharacters", ["count": 1]) }
    }

    func enter() {
        Task { await call("ssap://com.webos.service.ime/sendEnterKey") }
    }

    func toast(_ message: String) {
        Task { await call("ssap://system.notifications/createToast", ["message": message]) }
        show("Sent to the TV")
    }

    func sleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes else { sleepAt = nil; show("Sleep timer off"); return }
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        sleepAt = end
        show("TV turns off in \(minutes) min")
        sleepTask = Task {
            if minutes > 1 {
                try? await Task.sleep(until: .now + .seconds(Double(minutes - 1) * 60))
                guard !Task.isCancelled else { return }
                await call("ssap://system.notifications/createToast", ["message": "TV turns off in 1 minute"])
                try? await Task.sleep(for: .seconds(60))
            } else {
                try? await Task.sleep(for: .seconds(60))
            }
            guard !Task.isCancelled else { return }
            await call("ssap://system/turnOff")
            sleepAt = nil
        }
    }

    /// Saves the current frame to the Desktop and copies it.
    func saveScreenshot() {
        guard let frame else { show("No picture yet"); return }
        let image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
        let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent("TV \(stamp).png")
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        show("Screenshot copied and saved to Desktop")
    }

    // MARK: YouTube

    func sendYouTube(_ text: String, queue: Bool = false) -> Bool {
        guard let id = youTubeID(text) else { show("That is not a YouTube link"); return false }
        guard let host = current?.host else { return false }
        show(queue ? "Adding to the TV's queue…" : "Opening on the TV…")
        Task {
            do {
                try await YouTubeCast.send(videoID: id, to: host, queue: queue)
                show(queue ? "Added to the queue" : "Playing on the TV")
                await remember(id)
            } catch {
                show("YouTube didn't answer: \(error.localizedDescription)")
            }
        }
        return true
    }

    private func remember(_ id: String) async {
        sent.removeAll { $0.id == id }
        sent.insert(SentVideo(id: id, title: "YouTube video", channel: ""), at: 0)
        if sent.count > 8 { sent.removeLast() }
        guard let info = await YouTubeCast.details(of: id), let i = sent.firstIndex(where: { $0.id == id }) else { return }
        sent[i].title = info.title
        sent[i].channel = info.channel
        sent[i].thumbnail = info.thumbnail
    }

    func show(_ text: String) {
        withAnimation(.spring(response: 0.3)) { notice = text }
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut) { notice = nil }
        }
    }
}
