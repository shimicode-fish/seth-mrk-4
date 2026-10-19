import SwiftUI
import UIKit

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
            .background(Chamfer().fill(LinearGradient(colors: [azure.opacity(strong ? 0.62 : 0.28), azure.opacity(strong ? 0.38 : 0.16)], startPoint: .top, endPoint: .bottom)))
            .overlay(Chamfer().stroke(ice.opacity(0.85), lineWidth: 1))
            .shadow(color: azure.opacity(0.5), radius: 10)
    }
}

enum SethState { case idle, listening, thinking, speaking }

enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func done() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

// A slow drifting glow behind a faint grid. Holds still if Reduce Motion is on.
struct GridBG: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.05, blue: 0.14), Color(red: 0.01, green: 0.02, blue: 0.06)],
                           startPoint: .top, endPoint: .bottom)
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduce)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                GeometryReader { g in
                    Circle().fill(azure.opacity(0.22)).frame(width: 340, height: 340).blur(radius: 90)
                        .position(x: g.size.width * (0.3 + 0.25 * sin(t / 6)), y: g.size.height * (0.25 + 0.12 * cos(t / 7)))
                    Circle().fill(ice.opacity(0.10)).frame(width: 280, height: 280).blur(radius: 80)
                        .position(x: g.size.width * (0.75 + 0.15 * cos(t / 8)), y: g.size.height * (0.7 + 0.1 * sin(t / 5)))
                }
            }
            Canvas { ctx, size in
                var p = Path()
                for x in stride(from: 0, through: size.width, by: 40) { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }
                for y in stride(from: 0, through: size.height, by: 40) { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
                ctx.stroke(p, with: .color(azure.opacity(0.1)), lineWidth: 1)
            }
        }.ignoresSafeArea()
    }
}

// Seth's logo reacts to what he's doing: breathes at rest, ripples while listening,
// spins a ring while thinking, and pulses harder while he talks.
struct Logo: View {
    var state: SethState
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var appeared = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduce)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let speed: Double = state == .speaking ? 4.5 : (state == .idle ? 1.2 : 2.4)
            let pulse = (sin(t * speed) + 1) / 2
            ZStack {
                if state == .listening { ForEach(0..<3, id: \.self) { ring(t, $0) } }
                if state == .thinking {
                    Circle().trim(from: 0, to: 0.28).stroke(ice, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 156, height: 156).rotationEffect(.degrees(t * 280)).shadow(color: azure, radius: 8)
                }
                Image("Logo").resizable().scaledToFit().frame(width: 140, height: 140)
                    .scaleEffect(1 + pulse * (state == .speaking ? 0.07 : 0.035))
                    .shadow(color: azure.opacity(0.35 + 0.6 * pulse), radius: 8 + 20 * pulse)
            }
        }
        .frame(width: 190, height: 190)
        .scaleEffect(appeared ? 1 : 0.7).opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.7)) { appeared = true } }
    }

    private func ring(_ t: Double, _ i: Int) -> some View {
        let p = (t * 0.9 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
        return Circle().stroke(ice.opacity(0.55 * (1 - p)), lineWidth: 2).frame(width: 110, height: 110).scaleEffect(1 + p * 0.9)
    }
}

struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    let w = max(0, sin(t * 5 - Double(i) * 0.7))
                    Circle().fill(ice).frame(width: 7, height: 7).opacity(0.35 + 0.65 * w).offset(y: -3 * w)
                }
            }
            .panel(strong: false)
        }
    }
}

struct Bubble: View {
    let line: Brain.Line
    @State private var shown: String
    private let fresh: Bool

    init(line: Brain.Line) {
        self.line = line
        let isFresh = !line.mine && Date().timeIntervalSince(line.born ?? .distantPast) < 3
        fresh = isFresh
        _shown = State(initialValue: isFresh ? "" : line.text)
    }

    var body: some View {
        HStack {
            if line.mine { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                if !line.mine {
                    Text("SETH").font(.system(size: 11, weight: .heavy)).tracking(2).foregroundStyle(ice)
                }
                Text(shown).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).textSelection(.enabled)
            }
            .panel(strong: !line.mine)
            if !line.mine { Spacer(minLength: 48) }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task {
            guard fresh else { return }
            let step = min(0.014, 2.5 / Double(max(line.text.count, 1)))
            for ch in line.text {
                shown.append(ch)
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            }
            shown = line.text
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
    @State private var menuOpen = false
    @Environment(\.scenePhase) private var phase

    private var busy: Bool { brain.thinking || voice.speaking }
    private var state: SethState { listener.listening ? .listening : (brain.thinking ? .thinking : (voice.speaking ? .speaking : .idle)) }
    private var typing: Bool { !listener.listening && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var micIcon: String { typing ? "arrow.up" : (listener.listening ? "stop.fill" : (busy ? "hand.raised.fill" : "mic.fill")) }
    private var micLabel: String { typing || listener.listening ? "Send" : (busy ? "Interrupt Seth" : "Talk to Seth") }

    var body: some View {
        VStack(spacing: 0) {
            Logo(state: state)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").foregroundStyle(ice) }
                        .padding().accessibilityLabel("Settings")
                }
                .overlay(alignment: .topLeading) {
                    Button { menuOpen = true } label: { Image(systemName: "line.3.horizontal").foregroundStyle(ice) }
                        .padding().accessibilityLabel("Chats")
                }
            ModeSwitch(guide: $brain.guide).padding(.bottom, 8)
            if !brain.status.isEmpty || brain.canRetry {
                HStack(spacing: 8) {
                    Text(brain.status.isEmpty ? "Couldn't send that." : brain.status)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(ice.opacity(0.85))
                    if brain.canRetry { Button("RETRY") { brain.retry() }.font(.system(size: 11, weight: .heavy)).foregroundStyle(.white) }
                }.padding(.bottom, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(brain.lines) { Bubble(line: $0).id($0.id) }
                        if brain.thinking { HStack { ThinkingDots(); Spacer() }.id("dots").transition(.opacity) }
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: brain.lines.count)
                }
                .onChange(of: brain.lines.count) { _, _ in
                    if let last = brain.lines.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        if !last.mine { Haptic.done() }
                    }
                }
                .onChange(of: brain.thinking) { _, on in
                    if on { withAnimation { proxy.scrollTo("dots", anchor: .bottom) } }
                }
            }
            if listener.listening || !listener.heard.isEmpty {
                Text(listener.heard.isEmpty ? "LISTENING…" : listener.heard)
                    .font(.system(size: 15, weight: .semibold)).italic().foregroundStyle(ice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel(strong: false).padding(.horizontal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                TextField("", text: $draft, prompt: Text("Say something").foregroundColor(.white.opacity(0.4)))
                    .foregroundStyle(.white).submitLabel(.send).onSubmit(send)
                    .padding(12)
                    .background(Chamfer(cut: 10).fill(Color.black.opacity(0.35)))
                    .overlay(Chamfer(cut: 10).stroke(ice.opacity(0.6), lineWidth: 1))
                Button(action: { if typing { send() } else { mic() } }) {
                    Image(systemName: micIcon).contentTransition(.symbolEffect(.replace)).font(.system(size: 18, weight: .bold)).frame(width: 46, height: 46)
                        .background(Chamfer(cut: 10).fill(listener.listening ? ice : azure.opacity(typing ? 0.9 : 0.5)))
                        .overlay(Chamfer(cut: 10).stroke(ice, lineWidth: 1))
                        .foregroundStyle(listener.listening ? Color.black : Color.white)
                }.accessibilityLabel(micLabel)
            }.padding()
        }
        .background(GridBG())
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: listener.listening)
        .overlay(alignment: .leading) {
            if menuOpen {
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { menuOpen = false }
                    SideMenu(brain: brain, open: $menuOpen).transition(.move(edge: .leading))
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: menuOpen)
        .onChange(of: phase) { _, p in if p == .background { brain.autoBackup() } }
        .alert("Seth wants to make a change", isPresented: Binding(get: { brain.pending != nil }, set: { _ in }), actions: {
            Button("Allow") { brain.answer(true) }
            Button("Deny", role: .cancel) { brain.answer(false) }
        }, message: { Text(brain.pending?.text ?? "") })
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
        Haptic.tap()
        if listener.listening { listener.finish(); return }
        brain.interrupt()
        Task { await listener.start() }
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = ""
        Haptic.tap()
        brain.ask(t, spoken: false)
    }
}

struct SettingsView: View {
    @ObservedObject var brain: Brain
    @State private var key = Keychain.load()
    @AppStorage("whisperOn") private var whisperOn = true
    @ObservedObject private var voice = Voice.shared

    var body: some View {
        NavigationStack {
            Form {
                ForEach($brain.providers) { $p in ProviderSection(p: $p, brain: brain) }
                Section {
                    NavigationLink("What Seth remembers") { MemoryView() }
                    NavigationLink("What Seth did (undo)") { ActionsView(brain: brain) }
                    Button("Clear chat history", role: .destructive) { brain.clearChat() }
                }
                Section {
                    ElevenSettings(voice: voice)
                    Picker("iPhone voice (backup)", selection: $voice.voiceID) {
                        Text("Best available").tag("")
                        ForEach(Voice.choices(), id: \.identifier) { v in
                            Text(v.name + (v.quality == .premium ? " (Premium)" : v.quality == .enhanced ? " (Enhanced)" : "")).tag(v.identifier)
                        }
                    }
                    Button("Preview") { Voice.shared.say("Yo, it's Seth. wsg? This is how I sound.") }
                } header: { Text("Voice") } footer: { Text("Human voice sends what Seth says to ElevenLabs to be spoken, using your free monthly credits, and falls back to the iPhone voice if that fails. For a better iPhone voice, download a Premium one in iPhone Settings, Accessibility, Spoken Content, Voices.") }
                BackupSection(brain: brain)
                Section("Diagnostics") {
                    LabeledContent("AI status", value: brain.status.isEmpty ? "OK" : brain.status)
                    LabeledContent("Memories saved", value: "\(Memory.shared.items.count)")
                    LabeledContent("Chats saved", value: "\(brain.convos.count)")
                    LabeledContent("Calendar access", value: brain.calendarOn ? "On" : "Off")
                }
                Section("Permissions (all off until you turn them on)") {
                    Toggle("Read my calendar", isOn: Binding(get: { brain.calendarOn }, set: { v in Task { await brain.setCalendar(v) } }))
                    Toggle("Use my reminders", isOn: Binding(get: { brain.remindersOn }, set: { v in Task { await brain.setReminders(v) } }))
                    Toggle("Let Seth make changes (always asks you first)", isOn: $brain.editOn)
                    Toggle("Let Seth check weather and news", isOn: $brain.worldOn)
                    if brain.worldOn { TextField("Home city (for weather)", text: $brain.homeCity) }
                    Toggle("Whisper transcription of my voice (Groq)", isOn: $whisperOn)
                    Toggle("Speak replies to typed messages", isOn: $brain.voiceOn)
                }
                Section {
                    Text("The microphone is on only while the stop button shows, and speech is recognized on your iPhone when it supports that. Seth sends the AI service set in Brain.swift the text of what you say or type, plus what an enabled tool returns. The app has no camera, location, or background-activity access.")
                }
            }.navigationTitle("Seth")
        }
    }
}

// Casual: relaxed companion. Guide: structured, step-by-step help. The highlight slides between them.
struct ModeSwitch: View {
    @Binding var guide: Bool
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            seg("CASUAL", on: !guide) { guide = false }
            seg("GUIDE", on: guide) { guide = true }
        }
        .clipShape(Chamfer(cut: 8))
        .overlay(Chamfer(cut: 8).stroke(ice.opacity(0.8), lineWidth: 1))
        .frame(width: 220)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: guide)
    }

    private func seg(_ t: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button { Haptic.tap(); tap() } label: {
            Text(t).font(.system(size: 12, weight: .heavy)).tracking(2)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .foregroundStyle(on ? Color.white : ice.opacity(0.7))
                .background { if on { Chamfer(cut: 8).fill(azure.opacity(0.85)).matchedGeometryEffect(id: "pill", in: pill) } }
        }
    }
}

// The left menu: every conversation, newest first. Press and hold one to delete it.
struct SideMenu: View {
    @ObservedObject var brain: Brain
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SETH").font(.system(size: 13, weight: .heavy)).tracking(3).foregroundStyle(ice)
            Button { brain.newChat(); open = false } label: {
                Label("NEW CHAT", systemImage: "plus").font(.system(size: 13, weight: .heavy)).tracking(1)
                    .foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).panel()
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(brain.convos) { c in
                        Button { brain.switchTo(c.id); open = false } label: {
                            Text(c.title).lineLimit(1).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading).panel(strong: c.id == brain.currentID)
                        }
                        .contextMenu { Button("Delete", role: .destructive) { brain.deleteChat(c.id) } }
                    }
                }
            }
        }
        .padding().padding(.top, 40)
        .frame(width: 290).frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.02, green: 0.04, blue: 0.12).opacity(0.97).ignoresSafeArea())
    }
}
