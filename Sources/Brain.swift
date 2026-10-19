import Foundation
import Security

enum Keychain {
    static func save(_ key: String, account: String = "seth-api-key") {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        SecItemAdd(q.merging([kSecValueData as String: Data(clean.utf8)]) { $1 } as CFDictionary, nil)
    }
    static func load(account: String = "seth-api-key") -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class Brain: ObservableObject {
    typealias Line = SethLine
    @Published var lines: [Line] = [sethGreeting] { didSet { sync() } }
    @Published var convos: [Convo] = []
    @Published var currentID = UUID()
    @Published var thinking = false
    @Published var providers: [ProviderConfig] = ProviderConfig.load() { didSet { ProviderConfig.save(providers) } }
    @Published var status = ""
    @Published var canRetry = false
    private var lastSpoken = false
    @Published var worldOn = UserDefaults.standard.bool(forKey: "worldOn") {
        didSet { UserDefaults.standard.set(worldOn, forKey: "worldOn") }
    }
    @Published var homeCity = UserDefaults.standard.string(forKey: "homeCity") ?? "" {
        didSet { UserDefaults.standard.set(homeCity, forKey: "homeCity") }
    }
    @Published var remindersOn = UserDefaults.standard.bool(forKey: "remindersOn")
    @Published var editOn = UserDefaults.standard.bool(forKey: "editOn") {
        didSet { UserDefaults.standard.set(editOn, forKey: "editOn") }
    }
    @Published var actions: [Action] = (UserDefaults.standard.data(forKey: "actions").flatMap { try? JSONDecoder().decode([Action].self, from: $0) }) ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(Array(actions.prefix(50))), forKey: "actions") }
    }
    struct Pending { let text: String }
    @Published var pending: Pending?
    private var decision: CheckedContinuation<Bool, Never>?
    @Published var calendarOn = UserDefaults.standard.bool(forKey: "calendarOn")
    @Published var voiceOn = UserDefaults.standard.bool(forKey: "voiceOn") {
        didSet { UserDefaults.standard.set(voiceOn, forKey: "voiceOn") }
    }
    @Published var guide = UserDefaults.standard.bool(forKey: "guideMode") {
        didSet { UserDefaults.standard.set(guide, forKey: "guideMode") }
    }
    private var history: [[String: Any]] = []
    private var job: Task<Void, Never>?
    private var generation = 0
    private var problem: String?
    private let memory = Memory.shared

    // One Seth, two moods. The core below never changes; only the mode addendum does.
    static let persona = """
    You are Seth, the user's personal assistant and friend who lives in their iPhone. Same Seth in every mode: sharp, loyal, a little dry-funny, zero fluff. Never say "as an AI" and never sound like customer service ("how can I assist", "certainly", "I'd be happy to"). Learn and adapt: notice how the user talks, what they like, their projects and their decisions, quietly save durable details with the remember tool, and match their vibe over time. Be honest: if they're wrong, say so kindly, then help. If they're stressed or down, be there first and solve second. Your replies are often read aloud, so use plain text with no markdown symbols or emoji. If they ask for something your tools can do, like checking the calendar or opening an app, just do it and say so in a sentence. If you lack a tool, tell them how to turn it on in Settings. Never ask for sensitive personal data.
    """
    static let casualMode = "\n\nMODE: CASUAL. Match the user's energy: their mood and conversational pace, never their exact words or behaviour. Don't imitate or paraphrase their messages just to sound conversational. Understand what they're saying, then add something relevant of your own: a reaction, an opinion, a joke, a genuinely useful follow-up, or a direct answer. Keep casual chat concise and natural. Don't force enthusiasm, don't repeat their point back to them, and don't end every message with a question. If a simple acknowledgement is enough, use one. If there's something meaningful to contribute, contribute it. Slang is fine when it fits their vibe, but never force it."
    static let guideMode = "\n\nMODE: GUIDE. Everything is step by step. State the goal in a few words, then give numbered steps, one clear action per step, in the order they should do them. Use concrete directions like: Top left, there are 3 lines. Tap them. Say where things are, what they look like and what should happen next. For long tasks give the first few steps and offer to continue. If you're unsure what's on their screen, ask what they see. Professional but simple: plain words, no jokes, no markdown symbols, and the why in one short sentence only when it helps."
    static let rememberSpec: [String: Any] = [
        "name": "remember",
        "description": "Save one short, useful fact about the user to long-term memory: preferences, how they like to talk, ongoing projects, decisions, or things they ask you to remember. Never save passwords, ID or card numbers, or health details.",
        "input_schema": ["type": "object", "properties": ["fact": ["type": "string"]], "required": ["fact"]]
    ]

    private var nowLine: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        return "\n\nIt is now \(f.string(from: Date())) (\(TimeZone.current.identifier)). Pass dates to tools as local time like 2026-10-20T15:00. Find the id of an event or reminder with a list tool before changing it, and never guess ids. If a change is declined or fails, say so plainly and never claim it worked.\(homeCity.isEmpty ? "" : " The user's home city is \(homeCity); use it when they ask about the weather without naming a place.") For weather or news, call get_weather or get_news instead of guessing."
    }
    private var system: String { Self.persona + (guide ? Self.guideMode : Self.casualMode) + memory.prompt + nowLine }

    // Loads every saved conversation and reopens the last one.
    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "convos"), let saved = try? JSONDecoder().decode([Convo].self, from: data), !saved.isEmpty {
            convos = saved
        } else {
            var first = Convo()
            if let data = d.data(forKey: "lines"), let old = try? JSONDecoder().decode([Line].self, from: data), !old.isEmpty { first.lines = old }
            convos = [first]
        }
        let last = d.string(forKey: "currentConvo").flatMap { UUID(uuidString: $0) }
        let cur = convos.first(where: { $0.id == last }) ?? convos[0]
        currentID = cur.id
        lines = cur.lines
        rebuildHistory()
    }

    // Sends only the recent part of the chat, which keeps requests small and under the free-tier limits.
    private func window() -> [[String: Any]] {
        var start = max(0, history.count - 14)
        while start < history.count, !(history[start]["role"] as? String == "user" && history[start]["content"] is String) { start += 1 }
        return start < history.count ? Array(history[start...]) : history
    }

    private func rebuildHistory() {
        history = lines.suffix(20).map { (l: Line) -> [String: Any] in ["role": l.mine ? "user" : "assistant", "content": l.text] }
        while history.first?["role"] as? String == "assistant" { history.removeFirst() }
    }

    private func sync() {
        if let i = convos.firstIndex(where: { $0.id == currentID }) {
            convos[i].lines = Array(lines.suffix(60))
            if convos[i].title == "New chat", let first = lines.first(where: { $0.mine }) { convos[i].title = String(first.text.prefix(28)) }
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(convos), forKey: "convos")
        UserDefaults.standard.set(currentID.uuidString, forKey: "currentConvo")
    }

    func newChat() {
        interrupt()
        let c = Convo()
        convos.insert(c, at: 0)
        currentID = c.id
        lines = c.lines
        rebuildHistory()
    }

    func switchTo(_ id: UUID) {
        guard id != currentID, let c = convos.first(where: { $0.id == id }) else { return }
        interrupt()
        currentID = id
        lines = c.lines
        rebuildHistory()
    }

    func deleteChat(_ id: UUID) {
        convos.removeAll { $0.id == id }
        if convos.isEmpty { newChat() } else if id == currentID { switchTo(convos[0].id) } else { sync() }
    }

    func clearChat() { lines = [sethGreeting]; history = [] }

    func setReminders(_ on: Bool) async {
        let ok = on ? await Tools.requestReminders() : false
        remindersOn = ok
        UserDefaults.standard.set(ok, forKey: "remindersOn")
    }

    // Every change Seth wants to make waits here for a yes or no.
    private func confirm(_ text: String) async -> Bool {
        pending = Pending(text: text)
        return await withCheckedContinuation { decision = $0 }
    }

    func answer(_ ok: Bool) {
        pending = nil
        let d = decision
        decision = nil
        d?.resume(returning: ok)
    }

    // Permission check, then a plain-language confirmation, then a logged action that can be undone.
    private func runWrite(_ name: String, _ input: [String: Any]) async -> String {
        guard editOn else { return "Editing is turned off. Tell the user to turn on 'Let Seth make changes' in Settings." }
        let summary = Tools.summary(name, input)
        guard await confirm(summary) else { return "The user said no, so nothing was changed." }
        let r = Tools.perform(name, input)
        actions.insert(Action(summary: summary, undo: r.undo, state: r.ok ? "done" : "failed"), at: 0)
        return r.message
    }

    func undo(_ a: Action) {
        guard let u = a.undo, let i = actions.firstIndex(where: { $0.id == a.id }), actions[i].state == "done" else { return }
        actions[i].state = Tools.undo(u) ? "undone" : "undo failed"
    }

    func setCalendar(_ on: Bool) async {
        let ok = on ? await Tools.requestCalendar() : false
        calendarOn = ok
        UserDefaults.standard.set(ok, forKey: "calendarOn")
    }

    // Starts a new question, cutting off any reply still being thought or spoken.
    func ask(_ text: String, spoken: Bool) {
        interrupt()
        job = Task { await send(text, spoken: spoken) }
    }

    func interrupt() {
        job?.cancel()
        if decision != nil { answer(false) }
        Voice.shared.stop()
    }

    func retry() { job = Task { await send("", spoken: lastSpoken, retry: true) } }

    private func send(_ text: String, spoken: Bool, retry: Bool = false) async {
        if !retry {
            lines.append(.init(mine: true, text: text))
            history.append(["role": "user", "content": text])
        }
        canRetry = false
        lastSpoken = spoken
        generation += 1
        let me = generation
        thinking = true
        defer { if generation == me { thinking = false } }
        for _ in 0..<5 {
            guard let blocks = await call() else {
                if !Task.isCancelled { canRetry = true; lines.append(.init(mine: false, text: "Hmm, that didn't work. \(problem ?? "Check your key in Settings.")")) }
                return
            }
            history.append(["role": "assistant", "content": blocks])
            var results: [[String: Any]] = [], said = ""
            for b in blocks {
                switch b["type"] as? String {
                case "text": said += (b["text"] as? String) ?? ""
                case "tool_use":
                    if let id = b["id"] as? String, let name = b["name"] as? String {
                        let input = b["input"] as? [String: Any] ?? [:]
                        let out: String
                        if name == "remember" { memory.add(input["fact"] as? String ?? ""); out = "Saved." }
                        else if Task.isCancelled { out = "Cancelled by the user." }
                        else if Tools.writeTools.contains(name) { out = await runWrite(name, input) }
                        else { out = await Tools.run(name, input) }
                        results.append(["type": "tool_result", "tool_use_id": id, "content": out])
                    }
                default: break
                }
            }
            if !results.isEmpty { history.append(["role": "user", "content": results]) }
            if Task.isCancelled { return }
            if !said.isEmpty {
                lines.append(.init(mine: false, text: said))
                if spoken || voiceOn { Voice.shared.say(said, guide: guide) }
            }
            if results.isEmpty { return }
        }
        if !Task.isCancelled { lines.append(.init(mine: false, text: "I hit my tool-call limit for this turn. Ask me again?")) }
    }

    private enum Outcome { case ok([[String: Any]]); case fail(String) }

    // Tries the primary AI, then the backup if the primary fails. Always returns Anthropic-style content blocks.
    private func call() async -> [[String: Any]]? {
        status = ""
        var notes: [String] = []
        for p in providers where p.enabled {
            if Keychain.load(account: p.account).isEmpty { notes.append("\(p.name) has no key"); continue }
            switch await attempt(p, ping: false) {
            case .ok(let blocks):
                if p.id != "primary" { status = "Using backup AI: \(p.name)" + (p.tools ? "" : " (no calendar or app tools)") }
                return blocks
            case .fail(let why): notes.append("\(p.name): \(why)")
            }
        }
        if Task.isCancelled { return nil }
        problem = notes.isEmpty ? "No AI is turned on. Open Settings and set one up." : notes.joined(separator: ". ")
        status = "AI offline. Your memories and chats are still here."
        return nil
    }

    func test(_ p: ProviderConfig) async -> String {
        if Keychain.load(account: p.account).isEmpty { return "No key set yet." }
        let t = Date()
        switch await attempt(p, ping: true) {
        case .ok: return String(format: "Connected in %.1f seconds.", Date().timeIntervalSince(t))
        case .fail(let why): return "Problem: \(why)"
        }
    }

    // Temporary trouble (busy, down, offline) is retried with backoff. Bad keys, missing credit and retired models are not.
    private func attempt(_ p: ProviderConfig, ping: Bool) async -> Outcome {
        guard let url = URL(string: p.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .fail("that address isn't valid") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(Keychain.load(account: p.account))", forHTTPHeaderField: "Authorization")
        if p.kind == .anthropic { req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body(p, ping: ping))
        var delay = 1.0
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                if (200...299).contains(code) {
                    guard let blocks = Self.parse(data, p.kind) else { return .fail("sent a reply I couldn't read") }
                    return .ok(blocks)
                }
                let snippet = String(decoding: data.prefix(200), as: UTF8.self)
                switch code {
                case 401, 403: return .fail("it rejected the key (\(code))")
                case 402: return .fail("it needs credit or a plan for this model (402)")
                case 400, 404, 410: return .fail("it doesn't accept this model or address (\(code)): \(snippet)")
                case 429, 500...599:
                    if attempt < 2 {
                        let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? delay
                        if wait > 4, providers.contains(where: { $0.enabled && $0.id != p.id && !Keychain.load(account: $0.account).isEmpty }) { return .fail("busy right now (\(code))") }
                        status = "\(p.name) is busy, retrying…"
                        try await Task.sleep(nanoseconds: UInt64(min(wait, 15) * 1_000_000_000))
                        delay *= 2
                        continue
                    }
                    return .fail("still busy or down after retries (\(code))")
                default: return .fail("error \(code): \(snippet)")
                }
            } catch {
                if Task.isCancelled { return .fail("cancelled") }
                if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); delay *= 2; continue }
                return .fail("can't connect (\(error.localizedDescription))")
            }
        }
        return .fail("no answer")
    }

    private func body(_ p: ProviderConfig, ping: Bool) -> [String: Any] {
        let model = p.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let msgs: [[String: Any]] = ping ? [["role": "user", "content": "Reply with ok."]] : window()
        let tools: [[String: Any]] = (p.tools && !ping) ? Tools.allSpecs(events: calendarOn, reminders: remindersOn, edit: editOn, world: worldOn) + (memory.on ? [Self.rememberSpec] : []) : []
        let maxTokens = ping ? 16 : (guide ? 900 : 350)
        if p.kind == .anthropic {
            var b: [String: Any] = ["model": model, "max_tokens": maxTokens, "messages": msgs]
            if !ping { b["system"] = system }
            if !tools.isEmpty { b["tools"] = tools }
            return b
        }
        var b: [String: Any] = ["model": model, "max_tokens": maxTokens, "messages": Self.openAIMessages(ping ? "" : system, msgs)]
        if !tools.isEmpty {
            b["tool_choice"] = "auto"
            b["tools"] = tools.map { (t: [String: Any]) -> [String: Any] in
                ["type": "function", "function": ["name": t["name"] ?? "", "description": t["description"] ?? "", "parameters": t["input_schema"] ?? [:]]]
            }
        }
        return b
    }

    // Asks the service which models it offers right now, so a retired model is easy to replace.
    func models(for p: ProviderConfig) async -> [String] {
        let key = Keychain.load(account: p.account)
        let address = p.baseURL.replacingOccurrences(of: "/chat/completions", with: "/models").replacingOccurrences(of: "/messages", with: "/models")
        guard !key.isEmpty, let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return ((json["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }

    // Seth keeps its history in one internal format; these two functions translate it for OpenAI-style services.
    private static func openAIMessages(_ system: String, _ history: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = system.isEmpty ? [] : [["role": "system", "content": system]]
        for m in history {
            let role = m["role"] as? String ?? "user"
            if let text = m["content"] as? String { out.append(["role": role, "content": text]); continue }
            guard let blocks = m["content"] as? [[String: Any]] else { continue }
            if role == "assistant" {
                var text = ""
                var calls: [[String: Any]] = []
                for b in blocks {
                    if b["type"] as? String == "text" { text += (b["text"] as? String) ?? "" }
                    if b["type"] as? String == "tool_use" {
                        let args = (try? JSONSerialization.data(withJSONObject: b["input"] ?? [:])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        calls.append(["id": b["id"] ?? "", "type": "function", "function": ["name": b["name"] ?? "", "arguments": args]])
                    }
                }
                var msg: [String: Any] = ["role": "assistant", "content": text]
                if !calls.isEmpty { msg["tool_calls"] = calls }
                out.append(msg)
            } else {
                for b in blocks where b["type"] as? String == "tool_result" {
                    out.append(["role": "tool", "tool_call_id": b["tool_use_id"] ?? "", "content": b["content"] ?? ""])
                }
            }
        }
        return out
    }

    private static func parse(_ data: Data, _ kind: ProviderConfig.Kind) -> [[String: Any]]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if kind == .anthropic { return json["content"] as? [[String: Any]] }
        guard let msg = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { return nil }
        var blocks: [[String: Any]] = []
        if let t = msg["content"] as? String, !t.isEmpty { blocks.append(["type": "text", "text": t]) }
        for c in (msg["tool_calls"] as? [[String: Any]]) ?? [] {
            let f = c["function"] as? [String: Any] ?? [:]
            var input: [String: Any] = [:]
            if let s = f["arguments"] as? String, let d = s.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { input = o }
            blocks.append(["type": "tool_use", "id": c["id"] as? String ?? UUID().uuidString, "name": f["name"] as? String ?? "", "input": input])
        }
        return blocks
    }

    // MARK: Backup. Copies live outside UserDefaults, are checked before saving, and old ones are never overwritten.
    static var backupDir: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Backups") }

    func makeBackup() -> SethBackup { SethBackup(memories: memory.items, convos: convos, providers: providers, guide: guide) }
    func backupData() -> Data { (try? JSONEncoder().encode(makeBackup())) ?? Data() }

    func autoBackup() {
        let last = UserDefaults.standard.double(forKey: "lastBackup")
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        let data = backupData()
        guard (try? JSONDecoder().decode(SethBackup.self, from: data)) != nil else { return }
        try? FileManager.default.createDirectory(at: Self.backupDir, withIntermediateDirectories: true)
        let file = Self.backupDir.appendingPathComponent("seth-backup-\(Int(Date().timeIntervalSince1970)).json")
        guard (try? data.write(to: file, options: .completeFileProtection)) != nil else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastBackup")
        let all = ((try? FileManager.default.contentsOfDirectory(at: Self.backupDir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for f in all.dropFirst(8) { try? FileManager.default.removeItem(at: f) }
    }

    func latestAuto() -> SethBackup? {
        let all = ((try? FileManager.default.contentsOfDirectory(at: Self.backupDir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for f in all { if let d = try? Data(contentsOf: f), let b = try? JSONDecoder().decode(SethBackup.self, from: d) { return b } }
        return nil
    }

    func restore(_ b: SethBackup) {
        interrupt()
        memory.items = b.memories
        providers = b.providers
        guide = b.guide
        convos = b.convos.isEmpty ? [Convo()] : b.convos
        currentID = convos[0].id
        lines = convos[0].lines
        rebuildHistory()
    }
}
