import SwiftUI

struct Memo: Identifiable, Codable {
    var id = UUID()
    var text: String
}

// Long-term memory. Stored only on this iPhone; sent to the AI service with each message so Seth can use it.
@MainActor
final class Memory: ObservableObject {
    static let shared = Memory()
    @Published var items: [Memo] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: "memories") }
    }
    @Published var on = UserDefaults.standard.object(forKey: "memoryOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(on, forKey: "memoryOn") }
    }

    private init() {
        if let d = UserDefaults.standard.data(forKey: "memories"), let m = try? JSONDecoder().decode([Memo].self, from: d) { items = m }
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if on, !t.isEmpty, !items.contains(where: { $0.text == t }) { items.append(Memo(text: t)) }
    }

    var prompt: String {
        guard on, !items.isEmpty else { return "" }
        return "\n\nThings you remember about the user (use them naturally, never recite them):\n" + items.map { "- " + $0.text }.joined(separator: "\n")
    }
}

struct MemoryView: View {
    @ObservedObject var memory = Memory.shared
    @State private var newText = ""
    @State private var confirm = false

    var body: some View {
        List {
            Section {
                Toggle("Let Seth remember things", isOn: $memory.on)
            } footer: {
                Text("Memories are saved only on this iPhone, but they're sent to the AI service with each message so Seth can use them.")
            }
            Section("Add one") {
                HStack {
                    TextField("Something to remember", text: $newText)
                    Button("Add") { memory.add(newText); newText = "" }.disabled(newText.isEmpty)
                }
            }
            Section("Seth remembers (tap to edit, swipe to delete)") {
                ForEach($memory.items) { $m in TextField("Memory", text: $m.text, axis: .vertical) }
                    .onDelete { memory.items.remove(atOffsets: $0) }
            }
            if !memory.items.isEmpty {
                Section { Button("Forget everything", role: .destructive) { confirm = true } }
            }
        }
        .navigationTitle("Memory")
        .confirmationDialog("Forget everything Seth remembers?", isPresented: $confirm) {
            Button("Forget everything", role: .destructive) { memory.items.removeAll() }
        }
    }
}
