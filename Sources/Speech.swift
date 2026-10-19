import Speech
import AVFoundation

// Seth's voice: the best installed voice (premium > enhanced > standard) in your language.
@MainActor
final class Voice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Voice()
    @Published var speaking = false
    private let synth = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synth.delegate = self
    }

    @Published var voiceID = UserDefaults.standard.string(forKey: "voiceID") ?? "" {
        didSet { UserDefaults.standard.set(voiceID, forKey: "voiceID") }
    }

    @Published var human = UserDefaults.standard.object(forKey: "humanVoice") as? Bool ?? true {
        didSet { UserDefaults.standard.set(human, forKey: "humanVoice") }
    }
    @Published var elevenVoice = UserDefaults.standard.string(forKey: "elevenVoice") ?? "JBFqnCBsd6RMkjVDRZzb" {
        didSet { UserDefaults.standard.set(elevenVoice, forKey: "elevenVoice") }
    }
    private var chain: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var gen = 0

    // Seth speaks with a natural ElevenLabs voice when that works, and the iPhone's own voice when it doesn't.
    func say(_ text: String, guide: Bool = false) {
        let spoken = Self.pronounce(text)
        let key = Keychain.load(account: "seth-key-eleven")
        guard human, !key.isEmpty else { appleSay(spoken, guide: guide); return }
        let g = gen
        let prev = chain
        chain = Task {
            _ = await prev?.value
            guard g == gen else { return }
            speaking = true
            let parts = Array(Self.chunks(spoken).prefix(4))   // keeps free credits from running out on long replies
            let voice = elevenVoice
            guard !parts.isEmpty else { speaking = false; return }
            var next = Task { await Self.fetch(parts[0], voice: voice, key: key) }
            for i in parts.indices {
                let audio = await next.value
                if i + 1 < parts.count { let following = parts[i + 1]; next = Task { await Self.fetch(following, voice: voice, key: key) } }
                guard g == gen, !Task.isCancelled else { return }
                guard let audio else { appleSay(parts[i...].joined(separator: " "), guide: guide); return }
                await play(audio)
            }
            if g == gen { speaking = false }
        }
    }

    private func play(_ data: Data) async {
        prepareSession()
        guard let p = try? AVAudioPlayer(data: data) else { return }
        player = p
        p.play()
        while p.isPlaying { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord { try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers]) }
        try? session.setActive(true)
    }

    private func appleSay(_ text: String, guide: Bool) {
        prepareSession()
        let voice = voiceID.isEmpty ? Self.bestVoice() : (AVSpeechSynthesisVoice(identifier: voiceID) ?? Self.bestVoice())
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let s = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
            let u = AVSpeechUtterance(string: s)
            u.voice = voice
            u.rate = guide ? 0.47 : 0.52
            u.postUtteranceDelay = guide ? 0.25 : 0.1
            self.synth.speak(u)
        }
    }

    nonisolated private static func fetch(_ text: String, voice: String, key: String) async -> Data? {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)?output_format=mp3_44100_64") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": "eleven_flash_v2_5"])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 500 else { return nil }
        return data
    }

    // The voice service takes short requests, so replies are split at sentence boundaries.
    nonisolated private static func chunks(_ text: String, limit: Int = 180) -> [String] {
        var out: [String] = []
        var cur = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard var s = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
            while s.count > limit {
                let cut = s.prefix(limit).lastIndex(of: " ") ?? s.index(s.startIndex, offsetBy: limit)
                let head = String(s[..<cut])
                s = String(s[cut...]).trimmingCharacters(in: .whitespaces)
                if !cur.isEmpty { out.append(cur); cur = "" }
                out.append(head)
            }
            if cur.isEmpty { cur = s }
            else if cur.count + 1 + s.count <= limit { cur += " " + s }
            else { out.append(cur); cur = s }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // Slang and short forms are spoken in full: "wsg" becomes "what's good", not "w s g".
    nonisolated static func pronounce(_ text: String) -> String {
        let map: [String: String] = [
            "wsg": "what's good", "wyd": "what are you doing", "wdym": "what do you mean", "idk": "I don't know", "idc": "I don't care",
            "ngl": "not gonna lie", "tbh": "to be honest", "imo": "in my opinion", "fr": "for real", "rn": "right now",
            "omg": "oh my god", "smh": "shaking my head", "bc": "because", "tho": "though", "ty": "thank you", "thx": "thanks",
            "np": "no problem", "nvm": "never mind", "btw": "by the way", "brb": "be right back", "gg": "good game",
            "lol": "haha", "lmao": "haha", "asap": "as soon as possible", "ik": "I know", "irl": "in real life",
            "pls": "please", "u": "you", "ur": "your", "dm": "D M"
        ]
        var out = String(text.filter { !"*#`_".contains($0) })
        for (k, v) in map {
            out = out.replacingOccurrences(of: "\\b\(k)\\b", with: v, options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    static func choices() -> [AVSpeechSynthesisVoice] {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) && !$0.identifier.contains("synthesis.voice") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    func stop() {
        gen += 1
        chain?.cancel()
        player?.stop()
        synth.stopSpeaking(at: .immediate)
        speaking = false
    }

    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let full = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        func score(_ v: AVSpeechSynthesisVoice) -> Int { v.quality.rawValue * 2 + (v.language == full ? 1 : 0) }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) && !$0.identifier.contains("synthesis.voice") }
            .max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: full)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = true }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}

// Seth's ears: the microphone is live only while `listening` is true.
@MainActor
final class Listener: ObservableObject {
    @Published var heard = ""
    @Published var listening = false
    var onFinal: ((String) -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Timer?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var whisperOn: Bool { UserDefaults.standard.object(forKey: "whisperOn") as? Bool ?? true }

    func start() async {
        guard !listening else { return }
        guard await Self.authorized(), let rec = recognizer, rec.isAvailable else {
            heard = "Allow Microphone and Speech Recognition for Seth in iPhone Settings."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
            request = req
            if let old = recordingURL { try? FileManager.default.removeItem(at: old) }
            recordingURL = nil
            var file: AVAudioFile?
            if whisperOn {
                let fmt = engine.inputNode.outputFormat(forBus: 0)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("seth-\(UUID().uuidString).wav")
                file = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate,
                                                                     AVNumberOfChannelsKey: Int(fmt.channelCount), AVLinearPCMBitDepthKey: 16,
                                                                     AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
                if file != nil { recordingURL = url }
            }
            audioFile = file
            Self.tap(engine.inputNode, req, file)
            engine.prepare()
            try engine.start()
            heard = ""
            listening = true
            task = Self.recognize(rec, req) { [weak self] text, done in
                Task { @MainActor in self?.handle(text, done) }
            }
            rearm(8)
        } catch {
            heard = "Couldn't start the microphone."
            stop()
        }
    }

    // Ends listening and sends what was heard.
    func finish() {
        guard listening else { return }
        let apple = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = recordingURL
        stop()
        guard !apple.isEmpty else { heard = ""; return }
        let key = Keychain.load()
        guard whisperOn, !key.isEmpty, let file else { heard = ""; onFinal?(apple); return }
        heard = apple + " …"   // Whisper is cleaning it up
        Task {
            let better = await Self.whisper(file, key: key)
            heard = ""
            onFinal?(better ?? apple)
            try? FileManager.default.removeItem(at: file)
        }
    }

    // Whisper (on Groq) transcribes slang and accents better than the built-in recognizer. If it fails, the built-in text is used.
    nonisolated private static func whisper(_ file: URL, key: String) async -> String? {
        guard let audio = try? Data(contentsOf: file), audio.count > 4000,
              let api = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions") else { return nil }
        let boundary = UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", "whisper-large-v3-turbo")
        field("response_format", "text")
        field("temperature", "0")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: api, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (out, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func stop() {
        silence?.invalidate()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        audioFile = nil
        listening = false
    }

    private func handle(_ text: String?, _ done: Bool) {
        guard listening else { return }
        if let text, !text.isEmpty { heard = text; rearm(1.4) }
        if done { finish() }
    }

    private func rearm(_ seconds: TimeInterval) {
        silence?.invalidate()
        silence = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    nonisolated private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
    }

    nonisolated private static func tap(_ input: AVAudioInputNode, _ req: SFSpeechAudioBufferRecognitionRequest, _ file: AVAudioFile?) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            req.append(buffer)
            try? file?.write(from: buffer)
        }
    }

    nonisolated private static func recognize(_ rec: SFSpeechRecognizer, _ req: SFSpeechAudioBufferRecognitionRequest,
                                              _ cb: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        rec.recognitionTask(with: req) { result, error in
            cb(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || error != nil)
        }
    }
}
