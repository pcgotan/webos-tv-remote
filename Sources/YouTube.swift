import AppKit

/// Plays videos in the TV's own YouTube app, the way a phone "casts" to it:
/// DIAL finds the app and its screen id, then the YouTube Lounge API sets the playlist.
enum YouTubeCast {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    // LG's DIAL server refuses requests without an app origin (and browser-like ones).
    private static let origin = "package:com.google.android.youtube"
    private static var appURLs: [String: URL] = [:]

    static func send(videoID: String, to host: String, queue: Bool) async throws {
        let screen = try await screenID(host: host)
        let token = try await loungeToken(screen)
        let bind = URL(string: "https://www.youtube.com/api/lounge/bc/bind")!
        var params = ["device": "REMOTE_CONTROL", "mdx-version": "3", "ui": "1", "v": "2", "name": "TV Remote",
                      "app": "youtube-desktop", "loungeIdToken": token, "id": UUID().uuidString, "VER": "8", "CVER": "1"]
        let opened = try await form(bind, query: params.merging(["RID": "1", "zx": zx()]) { $1 }, body: ["count": "0"])
        guard let sid = opened.firstMatch(#"\["c","([^"]+)""#), let gsession = opened.firstMatch(#"\["S","([^"]+)"\]"#) else {
            throw Failure("could not open a session")
        }
        params.merge(["SID": sid, "gsessionid": gsession, "RID": "2", "AID": "5", "zx": zx()]) { $1 }
        let command: [String: String] = queue
            ? ["count": "1", "ofs": "0", "req0__sc": "addVideo", "req0_videoId": videoID]
            : ["count": "1", "ofs": "0", "req0__sc": "setPlaylist", "req0_videoId": videoID, "req0_currentTime": "0",
               "req0_currentIndex": "0", "req0_videoIds": videoID, "req0_listId": ""]
        _ = try await form(bind, query: params, body: command)
    }

    /// Title, channel and thumbnail from YouTube's public oEmbed endpoint (no API key).
    static func details(of id: String) async -> (title: String, channel: String, thumbnail: NSImage?)? {
        guard let url = URL(string: "https://www.youtube.com/oembed?format=json&url=https://www.youtube.com/watch?v=\(id)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? JSON else { return nil }
        var thumbnail: NSImage?
        if let link = json["thumbnail_url"] as? String, let thumbURL = URL(string: link),
           let (image, _) = try? await URLSession.shared.data(from: thumbURL) { thumbnail = NSImage(data: image) }
        return (json["title"] as? String ?? "YouTube video", json["author_name"] as? String ?? "", thumbnail)
    }

    /// The YouTube app's screen id, from its DIAL status. Starts the app first if it isn't running.
    private static func screenID(host: String) async throws -> String {
        let app = try await appURL(host: host).appendingPathComponent("YouTube")
        for attempt in 0..<16 {
            var request = URLRequest(url: app)
            request.setValue(origin, forHTTPHeaderField: "Origin")
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let xml = String(data: data, encoding: .utf8) {
                if let id = xml.firstMatch(#"<screenId>(\w+)</screenId>"#), xml.contains("<state>running</state>") { return id }
                if attempt == 0 {  // not running: ask DIAL to start it, then wait for the screen id
                    request.httpMethod = "POST"
                    request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
                    _ = try? await URLSession.shared.data(for: request)
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw Failure("YouTube did not start on the TV")
    }

    /// The DIAL application URL. LG serves the DIAL description on port 1260; the apps port changes.
    private static func appURL(host: String) async throws -> URL {
        if let url = appURLs[host] { return url }
        guard let (_, response) = try? await URLSession.shared.data(from: URL(string: "http://\(host):1260/")!),
              let link = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Application-URL"),
              let url = URL(string: link) else { throw Failure("the TV has no DIAL service") }
        appURLs[host] = url
        return url
    }

    private static func loungeToken(_ screen: String) async throws -> String {
        let reply = try await form(URL(string: "https://www.youtube.com/api/lounge/pairing/get_lounge_token_batch")!,
                                   query: [:], body: ["screen_ids": screen])
        guard let json = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? JSON,
              let screens = json["screens"] as? [JSON], let token = screens.first?["loungeToken"] as? String else {
            throw Failure("no lounge token")
        }
        return token
    }

    private static func form(_ url: URL, query: [String: String], body: [String: String]) async throws -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var encoded = URLComponents()
        encoded.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((encoded.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("YouTube returned an error") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func zx() -> String { String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! }) }
}

extension String {
    func firstMatch(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
