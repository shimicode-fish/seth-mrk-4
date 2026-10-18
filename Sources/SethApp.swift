import SwiftUI

@main
struct SethApp: App {
    var body: some Scene { WindowGroup { SethView().preferredColorScheme(.dark) } }
}

private let ice = Color(red: 0.55, green: 0.82, blue: 1)
private let azure = Color(red: 0.1, green: 0.38, blue: 0.95)

// The blue "system window" look: translucent azure, cut corners, thin ice-blue edge, soft glow.
struct Chamfer: Shape {
    var cut: CGFloat = 14
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + cut, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - cut, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + cut))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - cut))
        p.addLine(to: CGPoint(x: r.maxX - cut, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + cut, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - cut))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + cut))
        p.closeSubpath()
        return p
    }
}

extension View {
    func panel(strong: Bool = true) -> some View {
        padding(14)
            .background(Chamfer().fill(azure.opacity(strong ? 0.5 : 0.22)))
            .overlay(Chamfer().stroke(ice.opacity(0.85), lineWidth: 1))
            .shadow(color: azure.opacity(0.5), radius: 10)
    }
}

struct GridBG: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.05, blue: 0.14), Color(red: 0.01, green: 0.02, blue: 0.06)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                var p = Path()
                for x in stride(from: 0, through: size.width, by: 40) { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }
                for y in stride(from: 0, through: size.height, by: 40) { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
                ctx.stroke(p, with: .color(azure.opacity(0.1)), lineWidth: 1)
            }
        }.ignoresSafeArea()
    }
}

// Seth's logo. Glows slowly at rest and faster while listening, thinking or talking.
struct Logo: View {
    var active: Bool
    @State private var glow = false

    var body: some View {
        Image("Logo").resizable().scaledToFit().frame(width: 140, height: 140)
            .shadow(color: azure.opacity(glow ? 0.95 : 0.4), radius: glow ? 26 : 10)
            .scaleEffect(glow ? 1.04 : 0.98)
            .onAppear { pulse() }
            .onChange(of: active) { _, _ in glow = false; pulse() }
    }
    private func pulse() {
        withAnimation(.easeInOut(duration: active ? 0.6 : 2.2).repeatForever(autoreverses: true)) { glow = true }
    }
}

struct Bubble: View {
    let line: Brain.Line
    var body: some View {
        HStack {
            if line.mine { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                if !line.mine {
                    Text("SETH").font(.system(size: 11, weight: .heavy)).tracking(2).foregroundStyle(ice)
                }
                Text(line.text).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            }
            .panel(strong: !line.mine)
            if !line.mine { Spacer(minLength: 48) }
        }
    }
}

struct SethView: View {
    @StateObject private var brain = Brain()
    @StateObject private var listener = Listener()
    @ObservedObject private var voice = Voice.shared
    @ObservedObject private var launch = Launch.shared
    @State private var draft = ""
    @State private var showSettings = false

    private var busy: Bool { brain.thinking || voice.speaking }
    private var typing: Bool { !listener.listening && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var micIcon: String { typing ? "arrow.up" : (listener.listening ? "stop.fill" : (busy ? "hand.raised.fill" : "mic.fill")) }
    private var micLabel: String { typing || listener.listening ? "Send" : (busy ? "Interrupt Seth" : "Talk to Seth") }

    var body: some View {
        VStack(spacing: 0) {
            Logo(active: busy || listener.listening)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").foregroundStyle(ice) }
                        .padding().accessibilityLabel("Settings")
                }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(brain.lines) { Bubble(line: $0).id($0.id) }
                    }.padding(.horizontal).padding(.vertical, 8)
                }
                .onChange(of: brain.lines.count) { _, _ in
                    if let last = brain.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if listener.listening || !listener.heard.isEmpty {
                Text(listener.heard.isEmpty ? "LISTENING…" : listener.heard)
                    .font(.system(size: 15, weight: .semibold)).italic().foregroundStyle(ice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel(strong: false).padding(.horizontal)
            }
            HStack(spacing: 10) {
                TextField("", text: $draft, prompt: Text("Say something").foregroundColor(.white.opacity(0.4)))
                    .foregroundStyle(.white).submitLabel(.send).onSubmit(send)
                    .padding(12)
                    .background(Chamfer(cut: 10).fill(Color.black.opacity(0.35)))
                    .overlay(Chamfer(cut: 10).stroke(ice.opacity(0.6), lineWidth: 1))
                Button(action: { if typing { send() } else { mic() } }) {
                    Image(systemName: micIcon).font(.system(size: 18, weight: .bold)).frame(width: 46, height: 46)
                        .background(Chamfer(cut: 10).fill(listener.listening ? ice : azure.opacity(typing ? 0.9 : 0.5)))
                        .overlay(Chamfer(cut: 10).stroke(ice, lineWidth: 1))
                        .foregroundStyle(listener.listening ? Color.black : Color.white)
                }.accessibilityLabel(micLabel)
            }.padding()
        }
        .background(GridBG())
        .sheet(isPresented: $showSettings) { SettingsView(brain: brain) }
        .onAppear {
            listener.onFinal = { brain.ask($0, spoken: true) }
            if launch.wantsListen { listenNow() }
        }
        .onChange(of: launch.wantsListen) { _, want in if want { listenNow() } }
    }

    // The Action Button (or Siri) opened Seth: start listening right away.
    private func listenNow() {
        launch.wantsListen = false
        brain.interrupt()
        Task { await listener.start() }
    }

    // While Seth is thinking or talking, the button cuts him off and starts listening right away.
    private func mic() {
        if listener.listening { listener.finish(); return }
        brain.interrupt()
        Task { await listener.start() }
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = ""
        brain.ask(t, spoken: false)
    }
}

struct SettingsView: View {
    @ObservedObject var brain: Brain
    @State private var key = Keychain.load()

    var body: some View {
        NavigationStack {
            Form {
                Section("API key") {
                    SecureField("Paste your key", text: $key).onChange(of: key) { _, k in Keychain.save(k) }
                }
                Section("Permissions (all off until you turn them on)") {
                    Toggle("Read my calendar", isOn: Binding(get: { brain.calendarOn }, set: { v in Task { await brain.setCalendar(v) } }))
                    Toggle("Speak replies to typed messages", isOn: $brain.voiceOn)
                }
                Section {
                    Text("The microphone is on only while the stop button shows, and speech is recognized on your iPhone when it supports that. Seth sends the AI service set in Brain.swift the text of what you say or type, plus what an enabled tool returns. The app has no camera, location, or background-activity access.")
                }
            }.navigationTitle("Seth")
        }
    }
}
