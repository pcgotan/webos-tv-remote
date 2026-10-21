import AppKit
import SwiftUI

// MARK: - Building blocks

struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct RoundKey: View {
    let symbol: String
    var size: CGFloat = 42
    var tint: Color = .primary
    var help = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(.primary.opacity(hover ? 0.14 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(Press())
        .onHover { hover = $0 }
        .help(help)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }
}

// MARK: - Live view

/// Shows the last screenshot. It also holds keyboard focus, so Mac keys go to the TV, not a text field.
struct Picture: NSViewRepresentable {
    let image: CGImage?

    final class Surface: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspect
            layer?.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }
        }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    }

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        if view.layer?.contents as! CGImage? !== image { view.layer?.contents = image }
    }
}

struct ScreenCard: View {
    @ObservedObject var tv: TV

    var body: some View {
        ZStack {
            Picture(image: tv.frame)
            if tv.frame == nil { placeholder }
            VStack {
                HStack {
                    if let time = tv.frameTime {
                        Text("Captured \(time.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                    Spacer()
                    if tv.status == .online {
                        Button { tv.capture() } label: {
                            Label(tv.capturing ? "Capturing…" : "Capture", systemImage: "camera.viewfinder")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(tv.capturing)
                        .help("Show what's on the TV now (⌘R)")
                    }
                }
                Spacer()
                if let notice = tv.notice {
                    Text(notice).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(10)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.black, .indigo.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 12) {
                switch tv.status {
                case .pairing:
                    Image(systemName: "hand.tap.fill").font(.system(size: 34))
                    Text("Accept the prompt on your TV").font(.title3.weight(.semibold))
                    Text("Choose “Allow” with the TV remote. This happens only once.").foregroundStyle(.white.opacity(0.7))
                case .offline:
                    Image(systemName: "moon.zzz.fill").font(.system(size: 34))
                    Text("\(tv.name) is off or not reachable").font(.title3.weight(.semibold))
                    Button("Turn On") { tv.powerOn() }.buttonStyle(.borderedProminent)
                case .online:
                    Image(systemName: "sparkles.tv").font(.system(size: 34))
                    Text("Connected to \(tv.name)").font(.title3.weight(.semibold))
                    Text("Press Capture or ⌘R to see what's on the TV.").foregroundStyle(.white.opacity(0.7))
                default:
                    ProgressView().controlSize(.large).tint(.white)
                    Text(tv.current == nil ? "Looking for TVs…" : "Connecting to \(tv.name)…").foregroundStyle(.white.opacity(0.7))
                }
            }
            .foregroundStyle(.white)
        }
    }
}

// MARK: - YouTube

struct YouTubeBar: View {
    @ObservedObject var tv: TV
    @State private var link = ""
    @State private var copied: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill").font(.system(size: 18)).foregroundStyle(.red)
                TextField("Paste a YouTube link and press Return to play it on the TV", text: $link)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { send(queue: false) }
                if !link.isEmpty {
                    Button("Queue") { send(queue: true) }.controlSize(.small)
                    Button("Play") { send(queue: false) }.controlSize(.small).buttonStyle(.borderedProminent).tint(.red)
                } else if let copied {
                    Button { link = copied; send(queue: false) } label: {
                        Label("Play copied link", systemImage: "doc.on.clipboard").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered).tint(.red).controlSize(.small)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? Color.red.opacity(0.5) : .clear, lineWidth: 1.5))
            .animation(.easeOut(duration: 0.15), value: link.isEmpty)

            if !tv.sent.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(tv.sent) { video in
                            Button { _ = tv.sendYouTube(video.id) } label: { SentTile(video: video) }
                                .buttonStyle(Press())
                                .contextMenu {
                                    Button("Play Now") { _ = tv.sendYouTube(video.id) }
                                    Button("Add to Queue") { _ = tv.sendYouTube(video.id, queue: true) }
                                    Button("Copy Link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString("https://youtu.be/\(video.id)", forType: .string)
                                    }
                                }
                        }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: tv.sent)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in readClipboard() }
        .onAppear(perform: readClipboard)
    }

    private func send(queue: Bool) {
        if tv.sendYouTube(link, queue: queue) { link = ""; focused = false }
    }

    private func readClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        copied = text.contains("youtu") && youTubeID(text) != nil ? text : nil
    }
}

struct SentTile: View {
    let video: SentVideo
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Color.black
                if let thumb = video.thumbnail { Image(nsImage: thumb).resizable().scaledToFill() }
                Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white)
                    .padding(5).background(.black.opacity(0.5), in: Circle())
            }
            .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(video.channel).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
    }
}

// MARK: - Sidebar: remote, volume, apps, inputs

struct DPad: View {
    let tv: TV
    var body: some View {
        ZStack {
            Circle().fill(.primary.opacity(0.06))
            Circle().strokeBorder(.primary.opacity(0.08))
            arrow("chevron.up", "UP").offset(y: -50)
            arrow("chevron.down", "DOWN").offset(y: 50)
            arrow("chevron.left", "LEFT").offset(x: -50)
            arrow("chevron.right", "RIGHT").offset(x: 50)
            Button { tv.press("ENTER") } label: {
                Text("OK").font(.system(size: 15, weight: .semibold, design: .rounded))
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(.primary.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(Press())
        }
        .frame(width: 150, height: 150)
    }

    private func arrow(_ symbol: String, _ button: String) -> some View {
        Button { tv.press(button) } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(Press())
    }
}

struct Sidebar: View {
    @ObservedObject var tv: TV
    @State private var typed = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                nowPlaying
                if tv.keyboardOpen { typing.transition(.move(edge: .top).combined(with: .opacity)) }
                Card { remote }
                Card { volume }
                Card { apps }
                if !tv.inputs.isEmpty { Card { inputs } }
            }
            .padding(16)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: tv.keyboardOpen)
        }
        .scrollIndicators(.never)
    }

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            let app = tv.apps.first { $0.id == tv.foreground }
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(app?.color ?? .indigo)
                if let icon = app?.icon { Image(nsImage: icon).resizable().scaledToFit().padding(3) }
                else { Image(systemName: "tv").foregroundStyle(.white) }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("NOW ON TV").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).tracking(0.6)
                Text(app?.title ?? friendlyName(tv.foreground)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer()
            if let end = tv.sleepAt {
                Label { Text(end, style: .timer).monospacedDigit() } icon: { Image(systemName: "moon.fill") }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .animation(.easeInOut, value: tv.foreground)
    }

    private func friendlyName(_ id: String) -> String {
        switch id {
        case "": tv.status == .online ? "—" : "Not connected"
        case "com.gathin.tvhome", "com.webos.app.home": "Home"
        case "com.palm.app.settings": "Settings"
        default: tv.inputs.first { $0.appId == id }?.label ?? id
        }
    }

    private var typing: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard").foregroundStyle(Color.accentColor)
            TextField("Type on the TV, Return to send", text: $typed)
                .textFieldStyle(.plain).font(.system(size: 12))
                .onSubmit { tv.type(typed, replace: true); tv.enter(); typed = "" }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.12)))
    }

    private var remote: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(spacing: 12) {
                    RoundKey(symbol: "chevron.backward", help: "Back (⌫)") { tv.press("BACK") }
                    RoundKey(symbol: "house.fill", help: "Home (Esc)") { tv.press("HOME") }
                }
                Spacer()
                DPad(tv: tv)
                Spacer()
                VStack(spacing: 12) {
                    RoundKey(symbol: "playpause.fill", help: "Play / Pause") { tv.press("PLAY") }
                    RoundKey(symbol: "gearshape.fill", help: "TV settings") { tv.press("MENU") }
                }
            }
            HStack(spacing: 10) {
                RoundKey(symbol: "backward.fill", size: 34, help: "Rewind") { tv.press("REWIND") }
                RoundKey(symbol: "pause.fill", size: 34, help: "Pause") { tv.press("PAUSE") }
                RoundKey(symbol: "forward.fill", size: 34, help: "Fast-forward") { tv.press("FASTFORWARD") }
                Spacer()
                RoundKey(symbol: "chevron.up", size: 34, help: "Channel up") { tv.press("CHANNELUP") }
                RoundKey(symbol: "chevron.down", size: 34, help: "Channel down") { tv.press("CHANNELDOWN") }
            }
        }
    }

    private var volume: some View {
        HStack(spacing: 10) {
            Button { tv.toggleMute() } label: {
                Image(systemName: tv.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13)).foregroundStyle(tv.muted ? .red : .secondary).frame(width: 20)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(Press())
            Slider(value: Binding(get: { tv.volume }, set: { tv.setVolume($0) }), in: 0...100) { tv.draggingVolume = $0 }
                .controlSize(.small)
            Text("\(Int(tv.volume))").font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
        }
    }

    private var apps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APPS").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).tracking(0.6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(tv.apps) { app in
                    Button { tv.launch(app.id) } label: {
                        ZStack {
                            app.color
                            if let icon = app.icon { Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().padding(5) }
                            else { Text(app.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).padding(4) }
                        }
                        .frame(height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(tv.foreground == app.id ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(Press())
                    .help(app.title)
                }
            }
        }
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INPUTS").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).tracking(0.6)
            HStack(spacing: 6) {
                ForEach(tv.inputs) { input in
                    Button { tv.launch(input.appId) } label: {
                        HStack(spacing: 4) {
                            Circle().fill(input.connected ? .green : .secondary.opacity(0.4)).frame(width: 6, height: 6)
                            Text(input.label).font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(Capsule().fill(tv.foreground == input.appId ? Color.accentColor.opacity(0.25) : .primary.opacity(0.06)))
                    }
                    .buttonStyle(Press())
                }
                Button { tv.launch("com.webos.app.livetv") } label: {
                    Text("Live TV").font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(Capsule().fill(tv.foreground == "com.webos.app.livetv" ? Color.accentColor.opacity(0.25) : .primary.opacity(0.06)))
                }
                .buttonStyle(Press())
            }
        }
    }
}

// MARK: - First run: pick a TV

struct Onboarding: View {
    @ObservedObject var tv: TV
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tv.and.mediabox.fill").font(.system(size: 54))
                .foregroundStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom))
            Text("Connect to your LG TV").font(.largeTitle.weight(.semibold))
            Text("Your Mac and TV must be on the same Wi-Fi. The TV will ask you to allow the connection once.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            VStack(spacing: 8) {
                ForEach(tv.found, id: \.self) { found in
                    Button { tv.choose(found) } label: {
                        HStack {
                            Image(systemName: "tv")
                            VStack(alignment: .leading) {
                                Text(found.name).font(.system(size: 13, weight: .semibold))
                                Text(found.host).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(12).frame(width: 380)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.06)))
                    }
                    .buttonStyle(Press())
                }
                if tv.found.isEmpty {
                    if tv.status == .searching { ProgressView().padding() }
                    else { Text("No TVs found yet.").foregroundStyle(.secondary).padding() }
                }
            }
            Button("Search Again") { tv.discover() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { tv.discover() }
    }
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject var tv: TV
    @State private var message = ""
    @State private var showMessage = false

    var body: some View {
        Group {
            if tv.current == nil {
                Onboarding(tv: tv)
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 18) {
                        ScreenCard(tv: tv)
                        YouTubeBar(tv: tv)
                        hints
                    }
                    .padding(20)
                    Divider()
                    Sidebar(tv: tv).frame(width: 330)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .toolbar { toolbar }
        .navigationTitle(tv.current == nil ? "TV Remote" : tv.name)
        .onAppear { tv.connect(); tv.discover() }
    }

    private var hints: some View {
        HStack(spacing: 14) {
            hint("keyboard", "Arrows move · Return OK · ⌫ Back · Esc Home")
            hint("camera.viewfinder", "⌘R capture the screen")
            Spacer()
        }
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(tv.saved) { saved in
                    Button { tv.select(saved.id) } label: {
                        if saved.id == tv.currentID { Label(saved.name, systemImage: "checkmark") } else { Text(saved.name) }
                    }
                }
                let newOnes = tv.found.filter { f in !tv.saved.contains { $0.id == f.id || $0.host == f.host } }
                if !newOnes.isEmpty {
                    Divider()
                    ForEach(newOnes, id: \.self) { f in Button("Add \(f.name)") { tv.choose(f) } }
                }
                Divider()
                Button("Find TVs on This Network") { tv.discover() }
                if let id = tv.currentID { Button("Forget This TV", role: .destructive) { tv.forget(id) } }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.system(size: 12))
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { tv.saveScreenshot() } label: { Label("Save Screenshot", systemImage: "square.and.arrow.down") }
                .help("Copy the last capture and save it to the Desktop")
                .disabled(tv.frame == nil)
            Button { showMessage = true } label: { Label("Message", systemImage: "text.bubble") }
                .help("Show a message on the TV")
                .popover(isPresented: $showMessage) {
                    HStack {
                        TextField("Message to show on the TV", text: $message).frame(width: 240)
                            .onSubmit(sendMessage)
                        Button("Send", action: sendMessage).disabled(message.isEmpty)
                    }
                    .padding(12)
                }
            Menu {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { m in Button("\(m) minutes") { tv.sleepTimer(minutes: m) } }
                if tv.sleepAt != nil { Divider(); Button("Cancel Sleep Timer") { tv.sleepTimer(minutes: nil) } }
            } label: { Label("Sleep", systemImage: tv.sleepAt == nil ? "moon" : "moon.fill") }
                .help("Turn the TV off later (while this app is open)")
            Button { tv.status == .online ? tv.powerOff() : tv.powerOn() } label: {
                Label("Power", systemImage: "power")
            }
            .help(tv.status == .online ? "Turn the TV off" : "Turn the TV on (needs “Turn on via Wi-Fi” on the TV)")
        }
    }

    private func sendMessage() {
        guard !message.isEmpty else { return }
        tv.toast(message)
        message = ""
        showMessage = false
    }

    private var statusColor: Color {
        switch tv.status {
        case .online: .green
        case .connecting, .pairing, .searching: .orange
        case .offline, .idle: .secondary
        }
    }

    private var statusText: String {
        switch tv.status {
        case .online: tv.name
        case .connecting: "Connecting…"
        case .pairing: "Waiting for “Allow” on the TV"
        case .searching: "Searching…"
        case .offline: "\(tv.name) · offline"
        case .idle: tv.name
        }
    }
}
