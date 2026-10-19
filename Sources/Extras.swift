import SwiftUI

struct VoiceOption: Identifiable { let id: String; let name: String }

// Settings for Seth's ElevenLabs voice.
struct ElevenSettings: View {
    @ObservedObject var voice: Voice
    @State private var key = ""
    @State private var voices: [VoiceOption] = []
    @State private var note = ""

    var body: some View {
        Group {
            Toggle("Human voice (ElevenLabs)", isOn: $voice.human)
            if voice.human {
                SecureField("ElevenLabs API key", text: $key).onChange(of: key) { _, k in Keychain.save(k, account: "seth-key-eleven") }
                TextField("Voice ID", text: $voice.elevenVoice).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("List my voices") {
                    Task { voices = await Voice.listVoices(); note = voices.isEmpty ? "Couldn't list voices. Check the key." : "" }
                }
                if !voices.isEmpty {
                    Picker("Pick a voice", selection: $voice.elevenVoice) { ForEach(voices) { Text($0.name).tag($0.id) } }
                }
                if !note.isEmpty { Text(note).font(.footnote) }
            }
        }
        .onAppear { key = Keychain.load(account: "seth-key-eleven") }
    }
}

extension Voice {
    nonisolated static func listVoices() async -> [VoiceOption] {
        let key = Keychain.load(account: "seth-key-eleven")
        guard !key.isEmpty, let url = URL(string: "https://api.elevenlabs.io/v1/voices") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return ((json["voices"] as? [[String: Any]]) ?? []).compactMap { v in
            guard let id = v["voice_id"] as? String, let name = v["name"] as? String else { return nil }
            return VoiceOption(id: id, name: name)
        }
    }
}

// Seth's window on the world: weather and headlines. Only offered to the AI when you turn it on.
extension Tools {
    static func worldSpecs() -> [[String: Any]] {
        [spec("get_weather", "Get the current weather and a 3-day forecast for a city.", ["city": "City name, like Singapore"], ["city"]),
         spec("get_news", "Get today's top news headlines, optionally about a topic or place.", ["topic": "Optional topic or place, like football or Singapore"], [])]
    }

    private static func describe(_ c: Int) -> String {
        switch c {
        case 0: return "clear"
        case 1, 2: return "mostly clear"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51...57: return "drizzle"
        case 61...67: return "rain"
        case 71...77: return "snow"
        case 80...82: return "rain showers"
        case 95...99: return "thunderstorms"
        default: return "mixed"
        }
    }

    static func weather(_ city: String) async -> String {
        let c = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, let q = c.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let geoURL = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=1&language=en&format=json"),
              let (g, _) = try? await URLSession.shared.data(from: geoURL),
              let gj = try? JSONSerialization.jsonObject(with: g) as? [String: Any],
              let place = (gj["results"] as? [[String: Any]])?.first,
              let lat = place["latitude"] as? Double, let lon = place["longitude"] as? Double
        else { return "I couldn't find a place called \(c)." }
        let name = [place["name"] as? String, place["country"] as? String].compactMap { $0 }.joined(separator: ", ")
        let address = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=3"
        guard let wURL = URL(string: address),
              let (w, _) = try? await URLSession.shared.data(from: wURL),
              let wj = try? JSONSerialization.jsonObject(with: w) as? [String: Any],
              let cur = wj["current"] as? [String: Any], let daily = wj["daily"] as? [String: Any]
        else { return "I couldn't reach the weather service." }
        func n(_ k: String) -> Int { Int(((cur[k] as? Double) ?? 0).rounded()) }
        var out = "\(name) now: \(n("temperature_2m"))°C (feels like \(n("apparent_temperature"))°C), \(describe(n("weather_code"))), humidity \(n("relative_humidity_2m"))%, wind \(n("wind_speed_10m")) km/h."
        let days = daily["time"] as? [String] ?? []
        let hi = daily["temperature_2m_max"] as? [Double] ?? []
        let lo = daily["temperature_2m_min"] as? [Double] ?? []
        let rain = daily["precipitation_probability_max"] as? [Double] ?? []
        let codes = daily["weather_code"] as? [Double] ?? []
        for i in days.indices where i < hi.count && i < lo.count {
            out += "\n\(days[i]): \(describe(Int(i < codes.count ? codes[i] : 0))), \(Int(lo[i])) to \(Int(hi[i]))°C, rain chance \(Int(i < rain.count ? rain[i] : 0))%"
        }
        return out
    }

    static func news(_ topic: String) async -> String {
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = t.isEmpty ? "https://feeds.bbci.co.uk/news/rss.xml"
            : "https://news.google.com/rss/search?q=\(t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&hl=en&gl=US&ceid=US:en"
        guard let url = URL(string: address), let (data, _) = try? await URLSession.shared.data(from: url) else { return "I couldn't reach the news right now." }
        let heads = Headlines.parse(data)
        return heads.isEmpty ? "I couldn't find any headlines." : heads.prefix(8).joined(separator: "\n")
    }
}

final class Headlines: NSObject, XMLParserDelegate {
    private var out: [String] = []
    private var inItem = false
    private var field = ""
    private var title = ""
    private var date = ""

    static func parse(_ data: Data) -> [String] {
        let h = Headlines()
        let p = XMLParser(data: data)
        p.delegate = h
        p.parse()
        return h.out
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "item" { inItem = true; title = ""; date = "" }
        field = name
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) {
        guard inItem else { return }
        if field == "title" { title += s } else if field == "pubDate" { date += s }
    }
    func parser(_ parser: XMLParser, foundCDATA b: Data) {
        if inItem, field == "title" { title += String(decoding: b, as: UTF8.self) }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item" {
            inItem = false
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append("- \(t) (\(date.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16)))") }
        }
        field = ""
    }
}
