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

    func say(_ text: String) {
        let u = AVSpeechUtterance(string: String(text.filter { !"*#`_".contains($0) }))
        u.voice = Self.bestVoice()
        synth.speak(u)
    }

    func stop() {
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
            Self.tap(engine.inputNode, req)
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
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        heard = ""
        if !text.isEmpty { onFinal?(text) }
    }

    func stop() {
        silence?.invalidate()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
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

    nonisolated private static func tap(_ input: AVAudioInputNode, _ req: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            req.append(buffer)
        }
    }

    nonisolated private static func recognize(_ rec: SFSpeechRecognizer, _ req: SFSpeechAudioBufferRecognitionRequest,
                                              _ cb: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        rec.recognitionTask(with: req) { result, error in
            cb(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || error != nil)
        }
    }
}
