import EventKit
import UIKit

@MainActor
enum Tools {
    static let store = EKEventStore()

    static func requestCalendar() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    // Tools are only offered to the model when the matching permission is on.
    static func specs(calendar: Bool) -> [[String: Any]] {
        var t: [[String: Any]] = [[
            "name": "open_app",
            "description": "Open an iPhone app. Supported: calendar, maps, messages, mail, phone, music, notes, reminders, safari, settings.",
            "input_schema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]
        ]]
        if calendar {
            t.append([
                "name": "get_calendar_events",
                "description": "List the user's calendar events from now through the next N days (1-14).",
                "input_schema": ["type": "object", "properties": ["days_ahead": ["type": "integer"]], "required": ["days_ahead"]]
            ])
        }
        return t
    }

    static func run(_ name: String, _ input: [String: Any]) async -> String {
        switch name {
        case "open_app": return await open(input["name"] as? String ?? "")
        case "get_calendar_events": return events(days: input["days_ahead"] as? Int ?? 1)
        case "list_reminders": return await listReminders()
        case "get_weather": return await weather(input["city"] as? String ?? "")
        case "get_news": return await news(input["topic"] as? String ?? "")
        default: return "Unknown tool."
        }
    }

    static func events(days: Int) -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return "Calendar access is off." }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: max(1, min(days, 14)), to: start)!
        let list = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        if list.isEmpty { return "No events in that window." }
        return list.sorted { $0.startDate < $1.startDate }
            .map { "[\($0.eventIdentifier ?? "")] \($0.startDate.formatted(date: .abbreviated, time: .shortened)): \($0.title ?? "Untitled")" }
            .joined(separator: "\n")
    }

    static func open(_ name: String) async -> String {
        let map = ["calendar": "calshow://", "maps": "maps://", "messages": "sms:", "mail": "mailto:", "phone": "tel:",
                   "music": "music://", "notes": "mobilenotes://", "reminders": "x-apple-reminderkit://",
                   "safari": "https://", "settings": UIApplication.openSettingsURLString]
        guard let s = map[name.lowercased()], let url = URL(string: s) else { return "I can't open that app yet." }
        return await UIApplication.shared.open(url) ? "Opened \(name)." : "iOS wouldn't open \(name)."
    }
}
