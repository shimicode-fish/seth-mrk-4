
import Foundation
import Security
import Combine

enum Keychain {
    static func save(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "seth-api-key"
        ]
        SecItemDelete(q as CFDictionary)
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        SecItemAdd(
            q.merging([kSecValueData as String: Data(clean.utf8)]) { $1 }
                as CFDictionary,
            nil
        )
    }

    static func load() -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "seth-api-key",
            kSecReturnData as String: true
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class Brain: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        let mine: Bool
        let text: String
    }

    private static let defaultModel = "openai/gpt-oss-20b"

    @Published var lines: [Line] = [
        Line(mine: false, text: "Hey, I'm Seth. What's up?")
    ]
    @Published var thinking = false

    @Published var model: String = {
        let saved = UserDefaults.standard.string(forKey: "model")
        // Migrate the previous provider's default model.
        if saved == nil || saved == "gpt-5.6-sol" {
            return "openai/gpt-oss-20b"
        }
        return saved!
    }() {
        didSet {
            UserDefaults.standard.set(model, forKey: "model")
        }
    }

    @Published var availableModels: [String] = []

    @Published var calendarOn = UserDefaults.standard.bool(forKey: "calendarOn")

    @Published var voiceOn = UserDefaults.standard.bool(forKey: "voiceOn") {
        didSet {
            UserDefaults.standard.set(voiceOn, forKey: "voiceOn")
        }
    }

    // OpenAI-compatible conversation messages.
    private var history: [[String: Any]] = []
    private var job: Task<Void, Never>?
    private var generation = 0
    private var problem: String?

    private static let endpoint =
        URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    private static let modelsEndpoint =
        URL(string: "https://api.groq.com/openai/v1/models")!

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

    // Fetch model IDs currently returned by Groq.
    // Call this when opening the model selector in Settings.
    func refreshModels() async {
        let key = Keychain.load()
        guard !key.isEmpty else {
            problem = "Add your Groq API key in Settings."
            return
        }

        var request = URLRequest(url: Self.modelsEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                problem = "Couldn't fetch Groq models. Check your API key."
                return
            }

            let json = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
            let items = json?["data"] as? [[String: Any]] ?? []

            availableModels = items.compactMap { $0["id"] as? String }
                .sorted()

            if availableModels.isEmpty {
                problem = "Groq returned no models."
            }
        } catch {
            problem = "Couldn't reach Groq: \(error.localizedDescription)"
        }
    }

    // Starts a new question and interrupts any previous reply.
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
        defer {
            if generation == me { thinking = false }
        }

        // Allow several rounds of tool calls in one conversation turn.
        for _ in 0..<5 {
            guard !Task.isCancelled else { return }

            guard let message = await call() else {
                if !Task.isCancelled {
                    lines.append(.init(
                        mine: false,
                        text: "Hmm, that didn't work. \(problem ?? "Check your Groq key in Settings.")"
                    ))
                }
                return
            }

            history.append(message)

            let said = message["content"] as? String ?? ""
            let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []

            for toolCall in toolCalls {
                guard let id = toolCall["id"] as? String,
                      let function = toolCall["function"] as? [String: Any],
                      let name = function["name"] as? String else {
                    continue
                }

                let rawArguments = function["arguments"] as? String ?? "{}"
                let data = Data(rawArguments.utf8)
                let input = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any] ?? [:]

                let output: String
                if Task.isCancelled {
                    return
                } else {
                    output = await Tools.run(name, input)
                }

                // OpenAI-compatible tool result.
                history.append([
                    "role": "tool",
                    "tool_call_id": id,
                    "content": output
                ])
            }

            if Task.isCancelled { return }

            if !said.isEmpty {
                lines.append(.init(mine: false, text: said))
                if spoken || voiceOn {
                    Voice.shared.say(said)
                }
            }

            // No tool calls means the assistant turn is complete.
            if toolCalls.isEmpty { return }
        }

        if !Task.isCancelled {
            lines.append(.init(
                mine: false,
                text: "I hit the tool-call limit for this turn. Try asking me again."
            ))
        }
    }

    // Convert the existing Anthropic-shaped tool specs into Groq function tools.
    private func groqTools() -> [[String: Any]] {
        Tools.specs(calendar: calendarOn).compactMap { spec in
            guard let name = spec["name"] as? String,
                  let description = spec["description"] as? String,
                  let schema = spec["input_schema"] as? [String: Any] else {
                return nil
            }

            return [
                "type": "function",
                "function": [
                    "name": name,
                    "description": description,
                    "parameters": schema
                ]
            ]
        }
    }

    private func call() async -> [String: Any]? {
        problem = nil

        let key = Keychain.load()
        guard !key.isEmpty else {
            problem = "I don't have a Groq key yet. Open Settings and add it."
            return nil
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(key)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        var messages: [[String: Any]] = [
            ["role": "system", "content": Self.persona]
        ]
        messages.append(contentsOf: history)

        let body: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": messages,
            "tools": groqTools(),
            "tool_choice": "auto",
            "max_tokens": 1024
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            for attempt in 0..<2 {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    problem = "Groq returned an invalid response."
                    return nil
                }

                let status = http.statusCode
                let snippet = String(decoding: data.prefix(600), as: UTF8.self)

                if status == 429 && attempt == 0 {
                    let retryAfter = Double(
                        http.value(forHTTPHeaderField: "Retry-After") ?? ""
                    ) ?? 4

                    try await Task.sleep(
                        nanoseconds: UInt64(
                            min(max(retryAfter, 1), 15) * 1_000_000_000
                        )
                    )
                    if Task.isCancelled { return nil }
                    continue
                }

                guard (200...299).contains(status) else {
                    switch status {
                    case 401, 403:
                        problem = "Groq rejected the API key (error \(status))."
                    case 402:
                        problem = "Groq reports a billing or account restriction. \(snippet)"
                    case 429:
                        problem = "Groq rate or usage limit reached (429). Check your usage limits. \(snippet)"
                    case 400:
                        problem = "Groq rejected the request. Check the selected model and its supported features. \(snippet)"
                    default:
                        problem = "Groq returned error \(status): \(snippet)"
                    }
                    return nil
                }

                guard let json = try JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let message = first["message"] as? [String: Any] else {
                    problem = "I got a reply I couldn't read: \(snippet)"
                    return nil
                }

                return message
            }
        } catch {
            if !Task.isCancelled {
                problem = "I couldn't reach Groq: \(error.localizedDescription)"
            }
        }

        return nil
    }
}
