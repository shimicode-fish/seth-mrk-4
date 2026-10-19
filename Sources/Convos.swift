import Foundation

struct SethLine: Identifiable, Codable {
    var id = UUID()
    let mine: Bool
    let text: String
    var born: Date? = Date()
}

let sethGreeting = SethLine(mine: false, text: "yo, it's Seth. what's up?")

struct Convo: Identifiable, Codable {
    var id = UUID()
    var title = "New chat"
    var lines: [SethLine] = [sethGreeting]
}
