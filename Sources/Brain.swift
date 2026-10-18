import Foundation
import Security

enum Keychain {
    static func save(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "seth-api-key"]
        SecItemDelete(q as CFDictionary)
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        SecItemAdd(q.merging([kSecValueData as String: Data(clean.utf8)]) { $1 } as CFDictionary, nil)
    }
    static func load() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "seth-api-key", kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class Brain: ObservableObject {
    struct Line: Identifiable { let id = UUID(); let mine: Bool; let text: String }
    @Published var lines: [Line] = [Line(mine: false, text: "Hey, I'm Seth. What's up?")]
    @Published var thinking = false
    @Published var calendarOn = UserDefaults.standard.bool(forKey: "calendarOn")
    @Published var voiceOn = UserDefaults.standard.bool(forKey: "voiceOn") {
        didSet { UserDefaults.standard.set(voiceOn, forKey: "voiceOn") }
    }
    private var history: [[String: Any]] = []
    private var job: Task<Void, Never>?
    private var generation = 0
    private var problem: String?

    static let persona = """
    You're Seth, a friend who lives in the user's phone. Talk like a real friend chatting: casual, warm, \
    short, with contractions and a bit of humor when it fits. Never sound like customer service: no \
    "How can I assist you", "certainly", "I'd be happy to", or "as an AI". React to what they said first, \
    then help. Have opinions and give straight answers. If they're wrong, say so kindly, then help them fix it. \
    If they're stressed or down, be there first and solve second. When it matters, be strategic: break big \
    things into the next one or two steps. Your replies are often read aloud, so keep to a few plain sentences \
    with no markdown, lists, or emoji. If they ask for something your tools can do, like checking their \
    calendar or opening an app, just do it and tell them in a sentence. If you lack a tool, tell them how to \
    turn it on in Settings. Never ask for sensitive personal data.
    """

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
        Voice.shared.stop()
    }

    private func send(_ text: String, spoken: Bool) async {
        lines.append(.init(mine: true, text: text))
        history.append(["role": "user", "content": text])
        generation += 1
        let me = generation
        thinking = true
        defer { if generation == me { thinking = false } }
        for _ in 0..<5 {
            guard let blocks = await call() else {
                if !Task.isCancelled { lines.append(.init(mine: false, text: "Hmm, that didn't work. \(problem ?? "Check your key in Settings.")")) }
                return
            }
            history.append(["role": "assistant", "content": blocks])
            var results: [[String: Any]] = [], said = ""
            for b in blocks {
                switch b["type"] as? String {
                case "text": said += (b["text"] as? String) ?? ""
                case "tool_use":
                    if let id = b["id"] as? String, let name = b["name"] as? String {
                        let out = Task.isCancelled ? "Cancelled by the user." : await Tools.run(name, b["input"] as? [String: Any] ?? [:])
                        results.append(["type": "tool_result", "tool_use_id": id, "content": out])
                    }
                default: break
                }
            }
            if !results.isEmpty { history.append(["role": "user", "content": results]) }
            if Task.isCancelled { return }
            if !said.isEmpty {
                lines.append(.init(mine: false, text: said))
                if spoken || voiceOn { Voice.shared.say(said) }
            }
            if results.isEmpty { return }
        }
    }

    private func call() async -> [[String: Any]]? {
        problem = nil
        let key = Keychain.load()
        guard !key.isEmpty else { problem = "I don't have a key yet. Tap the sliders icon and paste it in."; return nil }
        guard let url = URL(string: "https://router.bynara.id/v1/messages") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": "gpt-5.6-sol",
            "max_tokens": 1024,
            "system": Self.persona,
            "messages": history,
            "tools": Tools.specs(calendar: calendarOn)
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
            guard (200...299).contains(status) else {
                problem = status == 401 || status == 403 ? "The router rejected my key (error \(status))." : "The router sent back error \(status): \(snippet)"
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]] else {
                problem = "I got a reply I couldn't read: \(snippet)"
                return nil
            }
            return content
        } catch {
            problem = "I couldn't reach the router: \(error.localizedDescription)"
            return nil
        }
    }
}
