import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct TVRemoteApp: App {
    @StateObject private var tv = TV()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("TV Remote", id: "main") {
            ContentView(tv: tv)
                .onAppear { delegate.attach(tv) }
        }
        .defaultSize(width: 1180, height: 720)
        .defaultPosition(.center)
        .windowToolbarStyle(.unified)
        .commands { TVCommands(tv: tv) }

        MenuBarExtra("TV Remote", systemImage: "tv") {
            Button("Show TV Remote") { showMainWindow() }
            Divider()
            Button("Play / Pause") { tv.press("PLAY") }
            Button(tv.muted ? "Unmute" : "Mute") { tv.toggleMute() }
            Button("Play Copied YouTube Link") { _ = tv.sendYouTube(NSPasteboard.general.string(forType: .string) ?? "") }
            Divider()
            Button("Turn TV Off") { tv.powerOff() }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

func showMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "TV Remote" || $0.contentViewController != nil && $0.canBecomeMain }) {
        window.makeKeyAndOrderFront(nil)
    }
}

struct TVCommands: Commands {
    @ObservedObject var tv: TV

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Toggle("Open at Login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }))
        }
        CommandMenu("TV") {
            Button("Home") { tv.press("HOME") }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Back") { tv.press("BACK") }.keyboardShortcut("[", modifiers: .command)
            Button("Play / Pause") { tv.press("PLAY") }.keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Volume Up") { tv.press("VOLUMEUP") }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { tv.press("VOLUMEDOWN") }.keyboardShortcut(.downArrow, modifiers: .command)
            Button(tv.muted ? "Unmute" : "Mute") { tv.toggleMute() }.keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Button("Play Copied YouTube Link") { _ = tv.sendYouTube(NSPasteboard.general.string(forType: .string) ?? "") }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Button("Capture Screen") { tv.capture() }.keyboardShortcut("r", modifiers: .command)
            Button("Save Screenshot") { tv.saveScreenshot() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Turn TV Off") { tv.powerOff() }
            Button("Turn TV On") { tv.powerOn() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var tv: TV?
    private var keyMonitor: Any?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    func attach(_ tv: TV) {
        guard self.tv == nil else { return }
        self.tv = tv
        installKeys(tv)
        installHotKeys(tv)
    }

    /// Mac keys drive the TV while this app is in front and no text field is being edited:
    /// arrows move, Return is OK, Backspace is Back, Esc is Home. When the TV's own keyboard is
    /// open, typing goes straight into it and Backspace deletes a character.
    private func installKeys(_ tv: TV) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }  // typing in our own text field
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.contains(.command) {
                if tv.keyboardOpen, event.charactersIgnoringModifiers == "v",
                   let text = NSPasteboard.general.string(forType: .string) {
                    tv.type(text, replace: false)
                    return nil
                }
                return event  // menus and shortcuts
            }
            switch Int(event.keyCode) {
            case kVK_UpArrow: tv.press("UP")
            case kVK_DownArrow: tv.press("DOWN")
            case kVK_LeftArrow: tv.press("LEFT")
            case kVK_RightArrow: tv.press("RIGHT")
            case kVK_Return, kVK_ANSI_KeypadEnter: tv.keyboardOpen ? tv.enter() : tv.press("ENTER")
            case kVK_Delete: tv.keyboardOpen ? tv.deleteBackward() : tv.press("BACK")
            case kVK_Escape: tv.press("HOME")
            default:
                guard tv.keyboardOpen, let text = event.characters, !text.isEmpty,
                      text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return event }
                tv.type(text, replace: false)
            }
            return nil
        }
    }

    /// System-wide shortcuts (Carbon hot keys: no Accessibility permission needed).
    private func installHotKeys(_ tv: TV) {
        HotKeys.install()
        HotKeys.add(kVK_ANSI_T) { showMainWindow() }
        HotKeys.add(kVK_ANSI_Y) { _ = tv.sendYouTube(NSPasteboard.general.string(forType: .string) ?? "") }
        HotKeys.add(kVK_UpArrow) { tv.press("VOLUMEUP") }
        HotKeys.add(kVK_DownArrow) { tv.press("VOLUMEDOWN") }
        HotKeys.add(kVK_ANSI_P) { tv.press("PLAY") }
    }
}

enum HotKeys {
    nonisolated(unsafe) static var actions: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) static var refs: [EventHotKeyRef?] = []

    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            DispatchQueue.main.async { HotKeys.actions[key.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Registers ⌥⌘ + key.
    static func add(_ keyCode: Int, _ action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(cmdKey | optionKey), EventHotKeyID(signature: 0x5456_524D, id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

// MARK: - Entry point and self-test

@MainActor
func selfTest() async -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ label: String) { print(ok ? "PASS" : "FAIL", label); if !ok { failures += 1 } }

    let ids = ["https://youtu.be/dQw4w9WgXcQ?t=1": "dQw4w9WgXcQ", "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=x": "dQw4w9WgXcQ",
               "https://youtube.com/shorts/dQw4w9WgXcQ": "dQw4w9WgXcQ", "https://example.com/watch?v=dQw4w9WgXcQ": "",
               "hello": ""]
    for (input, want) in ids { check((youTubeID(input) ?? "") == want, "youTubeID(\(input))") }

    let found = await Discovery.search()
    print("discovered:", found.map { "\($0.name) @ \($0.host)" })
    let tv = TV()
    check(tv.current != nil, "a saved TV exists")
    tv.connect()
    for _ in 0..<60 where tv.status != .online { try? await Task.sleep(for: .milliseconds(250)) }
    check(tv.status == .online, "connected to \(tv.current?.host ?? "?")")
    guard tv.status == .online else { return 1 }
    try? await Task.sleep(for: .seconds(3))
    check(!tv.apps.isEmpty, "apps loaded (\(tv.apps.count), \(tv.apps.filter { $0.icon != nil }.count) with icons)")
    print("inputs:", tv.inputs.map(\.label), "foreground:", tv.foreground, "volume:", tv.volume, "muted:", tv.muted)
    tv.capture()
    for _ in 0..<40 where tv.frame == nil { try? await Task.sleep(for: .milliseconds(100)) }
    check(tv.frame != nil, "on-demand capture (\(tv.frame?.width ?? 0)x\(tv.frame?.height ?? 0))")
    return failures == 0 ? 0 : 1
}

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            Task { @MainActor in exit(await selfTest()) }
            RunLoop.main.run()
        }
        TVRemoteApp.main()
    }
}
