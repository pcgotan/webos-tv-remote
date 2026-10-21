import AppKit
import SwiftUI

typealias JSON = [String: Any]

// Permissions asked for at pairing. Changing this list makes the TV show "Allow?" again.
let permissions = [
    "LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CLOSE", "TEST_OPEN", "TEST_PROTECTED", "CONTROL_AUDIO",
    "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_RECORDING",
    "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_TV", "CONTROL_POWER", "CONTROL_TV_SCREEN",
    "READ_APP_STATUS", "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST", "READ_NETWORK_STATE",
    "READ_RUNNING_APPS", "READ_TV_CHANNEL_LIST", "WRITE_NOTIFICATION_TOAST", "READ_POWER_STATE",
    "READ_COUNTRY_INFO", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD", "READ_INSTALLED_APPS",
    "READ_SETTINGS", "READ_STORAGE_DEVICE_LIST",
]

/// A TV this Mac has paired with. Kept in UserDefaults; the client key is what the TV issued on "Allow".
struct SavedTV: Codable, Identifiable, Hashable {
    var id: String          // the TV's UPnP UUID
    var name: String
    var host: String
    var clientKey: String?
    var mac: String?        // for Wake-on-LAN, learned from the ARP table while connected
}

enum Library {
    private static let key = "savedTVs"

    static func load() -> [SavedTV] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let tvs = try? JSONDecoder().decode([SavedTV].self, from: data) else { return [] }
        return tvs
    }

    static func save(_ tvs: [SavedTV]) {
        if let data = try? JSONEncoder().encode(tvs) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Finds LG webOS TVs on the local network with an SSDP search.
enum Discovery {
    struct Found: Hashable { let id: String; let name: String; let host: String }

    static func search(seconds: Double = 2.5) async -> [Found] {
        let raw = await Task.detached { ssdp(seconds: seconds) }.value
        var found: [Found] = []
        for (host, headers) in raw where !found.contains(where: { $0.host == host }) {
            let usn = headers["usn"] ?? host
            let id = usn.components(separatedBy: "::").first?.replacingOccurrences(of: "uuid:", with: "") ?? host
            var name = headers["dlnadevicename.lge.com"].flatMap { $0.removingPercentEncoding } ?? ""
            if name.isEmpty, let location = headers["location"], let url = URL(string: location),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let xml = String(data: data, encoding: .utf8),
               let range = xml.range(of: #"(?<=<friendlyName>)[^<]+"#, options: .regularExpression) {
                name = String(xml[range])
            }
            found.append(Found(id: id, name: name.isEmpty ? "LG TV (\(host))" : name, host: host))
        }
        return found
    }

    private static func ssdp(seconds: Double) -> [(String, [String: String])] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n" +
            "ST: urn:lge-com:service:webos-second-screen:1\r\n\r\n"
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")
        _ = message.withCString { text in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, text, strlen(text), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        var results: [(String, [String: String])] = []
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard n > 0 else { continue }
            let host = String(cString: inet_ntoa(from.sin_addr))
            var headers: [String: String] = [:]
            for line in String(decoding: buffer[0..<n], as: UTF8.self).components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            results.append((host, headers))
        }
        return results
    }
}

/// The MAC address the Mac's ARP table holds for a host (needed for Wake-on-LAN).
func macAddress(of host: String) -> String? {
    let arp = Process()
    arp.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
    arp.arguments = ["-n", host]
    let pipe = Pipe()
    arp.standardOutput = pipe
    guard (try? arp.run()) != nil else { return nil }
    arp.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard let range = out.range(of: #"([0-9a-f]{1,2}:){5}[0-9a-f]{1,2}"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
    // arp prints "f4:14:bf:3:d7:c"; pad each byte to two digits.
    return out[range].split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":")
}

/// Sends a Wake-on-LAN magic packet. Works only if the TV allows it ("Turn on via Wi-Fi").
func wakeOnLAN(mac: String) {
    let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
    guard bytes.count == 6 else { return }
    let packet = [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in bytes }
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(9).bigEndian
    addr.sin_addr.s_addr = INADDR_BROADCAST
    _ = packet.withUnsafeBytes { raw in
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, raw.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

/// Pulls the 11-character video id out of any YouTube link (or a bare id).
func youTubeID(_ text: String) -> String? {
    let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let idPattern = #"^[A-Za-z0-9_-]{11}$"#
    if s.range(of: idPattern, options: .regularExpression) != nil { return s }
    guard let url = URLComponents(string: s), let host = url.host?.lowercased(), host.contains("youtu") else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    let id: String?
    if host.hasSuffix("youtu.be") { id = parts.first }
    else if let v = url.queryItems?.first(where: { $0.name == "v" })?.value { id = v }
    else if parts.count >= 2, ["shorts", "live", "embed"].contains(parts[0]) { id = parts[1] }
    else { id = nil }
    guard let id, id.range(of: idPattern, options: .regularExpression) != nil else { return nil }
    return id
}

extension Color {
    init(hex: String) {
        let v = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x333333
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
