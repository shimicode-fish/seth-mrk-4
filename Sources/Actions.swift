import EventKit
import SwiftUI

struct UndoInfo: Codable { var kind: String; var ref: String; var old: [String: String] }

struct Action: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var summary: String
    var undo: UndoInfo?
    var state: String   // done, failed, undone, undo failed
}

// Seth's hands. Brain asks the user before any of these run, then logs them so they can be undone.
extension Tools {
    static let writeTools: Set<String> = ["create_event", "update_event", "delete_event", "create_reminder", "update_reminder", "delete_reminder"]

    static func requestReminders() async -> Bool { (try? await store.requestFullAccessToReminders()) ?? false }

    static func spec(_ name: String, _ desc: String, _ props: [String: String], _ required: [String]) -> [String: Any] {
        ["name": name, "description": desc,
         "input_schema": ["type": "object", "properties": props.mapValues { ["type": "string", "description": $0] }, "required": required]]
    }

    // Tools are only offered to the AI when the matching permission is on.
    static func allSpecs(events: Bool, reminders: Bool, edit: Bool, world: Bool = false) -> [[String: Any]] {
        var t = specs(calendar: events) + (world ? worldSpecs() : [])
        if reminders { t.append(spec("list_reminders", "List the user's open reminders and tasks with their ids.", [:], [])) }
        if edit && events {
            t.append(spec("create_event", "Create a calendar event.", ["title": "Event title", "start": "Local start time like 2026-10-20T15:00", "minutes": "Length in minutes, default 60", "notes": "Optional notes"], ["title", "start"]))
            t.append(spec("update_event", "Change an event. Get its id from get_calendar_events first.", ["id": "Event id", "title": "New title", "start": "New local start time", "minutes": "New length in minutes", "notes": "New notes"], ["id"]))
            t.append(spec("delete_event", "Delete an event. Get its id from get_calendar_events first.", ["id": "Event id"], ["id"]))
        }
        if edit && reminders {
            t.append(spec("create_reminder", "Create a reminder or task.", ["title": "Reminder title", "due": "Optional local due time like 2026-10-20T15:00", "notes": "Optional notes"], ["title"]))
            t.append(spec("update_reminder", "Change a reminder. Get its id from list_reminders first.", ["id": "Reminder id", "title": "New title", "due": "New local due time", "done": "true to mark it complete"], ["id"]))
            t.append(spec("delete_reminder", "Delete a reminder. Get its id from list_reminders first.", ["id": "Reminder id"], ["id"]))
        }
        return t
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()
    private static func parse(_ s: Any?) -> Date? { (s as? String).flatMap { fmt.date(from: String($0.prefix(16))) } }
    private static func text(_ d: Date?) -> String { d.map { fmt.string(from: $0) } ?? "" }
    private static func num(_ v: Any?) -> Double? { (v as? Double) ?? Double((v as? String) ?? "") }
    private static func ev(_ id: Any?) -> EKEvent? { (id as? String).flatMap { store.event(withIdentifier: $0) } }
    private static func rem(_ id: Any?) -> EKReminder? { (id as? String).flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder } }
    private static func due(_ r: EKReminder) -> Date? { r.dueDateComponents.flatMap { Calendar.current.date(from: $0) } }
    private static func comps(_ d: Date) -> DateComponents { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d) }
    private static func snap(_ e: EKEvent) -> [String: String] { ["title": e.title ?? "", "start": text(e.startDate), "end": text(e.endDate), "notes": e.notes ?? ""] }
    private static func snap(_ r: EKReminder) -> [String: String] { ["title": r.title ?? "", "due": text(due(r)), "done": r.isCompleted ? "1" : "0", "notes": r.notes ?? ""] }
    private static func fill(_ e: EKEvent, _ o: [String: String]) {
        e.title = o["title"]
        e.notes = o["notes"]
        e.startDate = parse(o["start"]) ?? Date()
        e.endDate = parse(o["end"]) ?? e.startDate.addingTimeInterval(3600)
    }
    private static func fill(_ r: EKReminder, _ o: [String: String]) {
        r.title = o["title"]
        r.notes = o["notes"]
        r.isCompleted = o["done"] == "1"
        r.dueDateComponents = parse(o["due"]).map { comps($0) }
    }

    // The plain-language sentence the user is asked to approve.
    static func summary(_ name: String, _ a: [String: Any]) -> String {
        let title = a["title"] as? String ?? ""
        let when = ((a["start"] ?? a["due"]) as? String ?? "").replacingOccurrences(of: "T", with: " ")
        let parts: [String?] = [title.isEmpty ? nil : "title \"\(title)\"", when.isEmpty ? nil : "time \(when)", (a["notes"] as? String).map { _ in "notes" }]
        let changes = parts.compactMap { $0 }.joined(separator: ", ")
        switch name {
        case "create_event": return "Add event \"\(title)\" at \(when)"
        case "update_event": return "Change event \"\(ev(a["id"])?.title ?? "?")\": \(changes)"
        case "delete_event": return "Delete event \"\(ev(a["id"])?.title ?? "?")\""
        case "create_reminder": return "Add reminder \"\(title)\"" + (when.isEmpty ? "" : " due \(when)")
        case "update_reminder": return "Change reminder \"\(rem(a["id"])?.title ?? "?")\": \(changes)" + ((a["done"] as? String) == "true" ? ", mark done" : "")
        case "delete_reminder": return "Delete reminder \"\(rem(a["id"])?.title ?? "?")\""
        default: return name
        }
    }

    static func perform(_ name: String, _ a: [String: Any]) -> (ok: Bool, message: String, undo: UndoInfo?) {
        do {
            switch name {
            case "create_event":
                guard let start = parse(a["start"]), let title = a["title"] as? String else { return (false, "I need a title and a start time like 2026-10-20T15:00.", nil) }
                let e = EKEvent(eventStore: store)
                e.calendar = store.defaultCalendarForNewEvents
                e.title = title
                e.startDate = start
                e.endDate = start.addingTimeInterval((num(a["minutes"]) ?? 60) * 60)
                e.notes = a["notes"] as? String
                try store.save(e, span: .thisEvent)
                return (true, "Created the event.", UndoInfo(kind: "deleteEvent", ref: e.eventIdentifier ?? "", old: [:]))
            case "update_event":
                guard let e = ev(a["id"]) else { return (false, "I couldn't find that event.", nil) }
                let old = snap(e)
                if let t = a["title"] as? String, !t.isEmpty { e.title = t }
                if let s = parse(a["start"]) { let len = e.endDate.timeIntervalSince(e.startDate); e.startDate = s; e.endDate = s.addingTimeInterval(len) }
                if let m = num(a["minutes"]) { e.endDate = e.startDate.addingTimeInterval(m * 60) }
                if let n = a["notes"] as? String { e.notes = n }
                try store.save(e, span: .thisEvent)
                return (true, "Updated the event.", UndoInfo(kind: "revertEvent", ref: e.eventIdentifier ?? "", old: old))
            case "delete_event":
                guard let e = ev(a["id"]) else { return (false, "I couldn't find that event.", nil) }
                let old = snap(e)
                try store.remove(e, span: .thisEvent)
                return (true, "Deleted the event.", UndoInfo(kind: "restoreEvent", ref: "", old: old))
            case "create_reminder":
                guard let title = a["title"] as? String else { return (false, "I need a title.", nil) }
                let r = EKReminder(eventStore: store)
                r.calendar = store.defaultCalendarForNewReminders()
                fill(r, ["title": title, "due": text(parse(a["due"])), "notes": (a["notes"] as? String) ?? ""])
                try store.save(r, commit: true)
                return (true, "Created the reminder.", UndoInfo(kind: "deleteReminder", ref: r.calendarItemIdentifier, old: [:]))
            case "update_reminder":
                guard let r = rem(a["id"]) else { return (false, "I couldn't find that reminder.", nil) }
                let old = snap(r)
                if let t = a["title"] as? String, !t.isEmpty { r.title = t }
                if let d = parse(a["due"]) { r.dueDateComponents = comps(d) }
                if let n = a["notes"] as? String { r.notes = n }
                if let done = a["done"] { r.isCompleted = (done as? Bool) ?? ((done as? String) == "true") }
                try store.save(r, commit: true)
                return (true, "Updated the reminder.", UndoInfo(kind: "revertReminder", ref: r.calendarItemIdentifier, old: old))
            case "delete_reminder":
                guard let r = rem(a["id"]) else { return (false, "I couldn't find that reminder.", nil) }
                let old = snap(r)
                try store.remove(r, commit: true)
                return (true, "Deleted the reminder.", UndoInfo(kind: "restoreReminder", ref: "", old: old))
            default:
                return (false, "I don't know that action.", nil)
            }
        } catch {
            return (false, "That didn't work: \(error.localizedDescription)", nil)
        }
    }

    static func undo(_ u: UndoInfo) -> Bool {
        do {
            switch u.kind {
            case "deleteEvent": guard let e = ev(u.ref) else { return false }; try store.remove(e, span: .thisEvent)
            case "revertEvent": guard let e = ev(u.ref) else { return false }; fill(e, u.old); try store.save(e, span: .thisEvent)
            case "restoreEvent": let e = EKEvent(eventStore: store); e.calendar = store.defaultCalendarForNewEvents; fill(e, u.old); try store.save(e, span: .thisEvent)
            case "deleteReminder": guard let r = rem(u.ref) else { return false }; try store.remove(r, commit: true)
            case "revertReminder": guard let r = rem(u.ref) else { return false }; fill(r, u.old); try store.save(r, commit: true)
            case "restoreReminder": let r = EKReminder(eventStore: store); r.calendar = store.defaultCalendarForNewReminders(); fill(r, u.old); try store.save(r, commit: true)
            default: return false
            }
            return true
        } catch { return false }
    }

    static func listReminders() async -> String {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return "Reminders access is off." }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let items: [EKReminder] = await withCheckedContinuation { c in
            store.fetchReminders(matching: predicate) { c.resume(returning: $0 ?? []) }
        }
        if items.isEmpty { return "No open reminders." }
        return items.prefix(30).map { r in
            "[\(r.calendarItemIdentifier)] \(r.title ?? "Untitled")" + (due(r).map { " (due \(text($0)))" } ?? "")
        }.joined(separator: "\n")
    }
}

struct ActionsView: View {
    @ObservedObject var brain: Brain
    var body: some View {
        List {
            if brain.actions.isEmpty { Text("Nothing yet. When Seth changes your calendar or reminders, it shows up here and you can undo it.") }
            ForEach(brain.actions) { a in
                VStack(alignment: .leading, spacing: 4) {
                    Text(a.summary)
                    Text("\(a.date.formatted(date: .abbreviated, time: .shortened)) · \(a.state)").font(.footnote).foregroundStyle(.secondary)
                    if a.undo != nil && a.state == "done" { Button("Undo") { brain.undo(a) }.buttonStyle(.borderless) }
                }
            }
        }
        .navigationTitle("What Seth did")
    }
}
