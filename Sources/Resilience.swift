import SwiftUI
import UniformTypeIdentifiers

// One AI service Seth can talk to. Addresses and models live here, never hardcoded in the app logic.
struct ProviderConfig: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case anthropic = "Claude-style", openai = "OpenAI-style" }
    var id: String            // "primary" or "backup"
    var name: String
    var kind: Kind
    var baseURL: String
    var model: String
    var tools: Bool
    var enabled: Bool
    var account: String { id == "primary" ? "seth-api-key" : "seth-key-backup" }   // Keychain slot (keys are never exported)

    static func load() -> [ProviderConfig] {
        if let d = UserDefaults.standard.data(forKey: "providers_v2"),
           let p = try? JSONDecoder().decode([ProviderConfig].self, from: d), !p.isEmpty { return p }
        return [
            ProviderConfig(id: "primary", name: "Groq", kind: .openai, baseURL: "https://api.groq.com/openai/v1/chat/completions",
                           model: "openai/gpt-oss-20b", tools: true, enabled: true),
            ProviderConfig(id: "backup", name: "NaraRouter", kind: .anthropic, baseURL: "https://router.bynara.id/v1/messages",
                           model: "gpt-5.6-sol", tools: true, enabled: false)
        ]
    }
    static func save(_ p: [ProviderConfig]) { UserDefaults.standard.set(try? JSONEncoder().encode(p), forKey: "providers_v2") }
}

// Everything Seth needs to come back after a wipe or a move to a new phone. No API keys.
struct SethBackup: Codable {
    var version = 1
    var date = Date()
    var memories: [Memo]
    var convos: [Convo]
    var providers: [ProviderConfig]
    var guide: Bool
}

struct BackupDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ProviderSection: View {
    @Binding var p: ProviderConfig
    @ObservedObject var brain: Brain
    @State private var key = ""
    @State private var result = ""
    @State private var found: [String] = []

    var body: some View {
        Section {
            Toggle(p.id == "primary" ? "Use primary AI" : "Use backup AI", isOn: $p.enabled)
            TextField("Name", text: $p.name)
            Picker("Format", selection: $p.kind) { ForEach(ProviderConfig.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            TextField("Address", text: $p.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Model", text: $p.model).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("API key", text: $key).onChange(of: key) { _, k in Keychain.save(k, account: p.account) }
            Button("List available models") {
                Task { found = await brain.models(for: p); result = found.isEmpty ? "Couldn't list models. Check the address and key." : "\(found.count) models found." }
            }
            if !found.isEmpty {
                Picker("Pick a model", selection: $p.model) { ForEach(found, id: \.self) { Text($0).tag($0) } }
            }
            Toggle("Supports tools (calendar, apps)", isOn: $p.tools)
            Button("Test connection") { result = "Testing…"; Task { result = await brain.test(p) } }
            if !result.isEmpty { Text(result).font(.footnote) }
        } header: {
            Text(p.id == "primary" ? "Primary AI" : "Backup AI (used if the primary fails)")
        } footer: {
            Text(p.id == "primary" ? "If this AI shuts down, switch its address, model and key here. Nothing else needs rebuilding." : "Groq, OpenAI and most free services use the OpenAI-style format. Claude-style is for Anthropic-compatible routers.")
        }
        .onAppear { key = Keychain.load(account: p.account) }
    }
}

struct BackupSection: View {
    @ObservedObject var brain: Brain
    @State private var exporting = false
    @State private var importing = false
    @State private var pending: SethBackup?
    @State private var note = ""

    var body: some View {
        Section {
            Button("Export backup file") { exporting = true }
            Button("Restore from a backup file") { importing = true }
            Button("Restore latest automatic backup") {
                if let b = brain.latestAuto() { pending = b } else { note = "No automatic backup yet." }
            }
            if !note.isEmpty { Text(note).font(.footnote) }
        } header: { Text("Backup and restore") } footer: {
            Text("Seth backs up your memories, chats and settings automatically, keeping several versions. Backups never include API keys.")
        }
        .fileExporter(isPresented: $exporting, document: BackupDoc(data: brain.backupData()), contentType: .json, defaultFilename: "Seth-backup") { _ in }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result, url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            if let d = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(SethBackup.self, from: d) { pending = b }
            else { note = "That file isn't a valid Seth backup." }
        }
        .confirmationDialog("Replace your current memories and chats with this backup?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Replace my data", role: .destructive) { if let b = pending { brain.restore(b) }; pending = nil }
        }
    }
}
