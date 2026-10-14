import Foundation
import PitchstoneSync

/// Data e stato di un esame, salvati nei tag del nodo (`data:2027-01-20`,
/// `stato:studio`): si sincronizzano con il nodo senza tabelle nuove (ADR 0012).
public struct ExamInfo: Sendable, Equatable {
    public enum Status: String, Sendable, CaseIterable {
        case planned = "pianificato"
        case studying = "studio"
        case passed = "superato"
        case failed = "non-superato"
    }

    /// Giorno dell'esame (anno, mese, giorno), senza ora né fuso.
    public var date: DateComponents?
    public var status: Status

    public init(date: DateComponents? = nil, status: Status = .planned) {
        self.date = date
        self.status = status
    }

    static let datePrefix = "data:"
    static let statusPrefix = "stato:"

    public static func parse(_ tags: [String]) -> ExamInfo {
        var info = ExamInfo()
        for tag in tags {
            let lower = tag.lowercased()
            if lower.hasPrefix(datePrefix) {
                let parts = lower.dropFirst(datePrefix.count).split(separator: "-").compactMap { Int($0) }
                if parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) {
                    info.date = DateComponents(year: parts[0], month: parts[1], day: parts[2])
                }
            } else if lower.hasPrefix(statusPrefix), let status = Status(rawValue: String(lower.dropFirst(statusPrefix.count))) {
                info.status = status
            }
        }
        return info
    }

    /// I tag del nodo con data e stato aggiornati; gli altri tag restano.
    public func applied(to tags: [String]) -> [String] {
        var result = tags.filter {
            let lower = $0.lowercased()
            return !lower.hasPrefix(Self.datePrefix) && !lower.hasPrefix(Self.statusPrefix)
        }
        if let date, let y = date.year, let m = date.month, let d = date.day {
            result.append(String(format: "data:%04d-%02d-%02d", y, m, d))
        }
        result.append(Self.statusPrefix + status.rawValue)
        return result
    }

    /// Giorni da `now` all'esame nel calendario dato (0 oggi, negativo se passato).
    public func daysLeft(from now: Date, calendar: Calendar = .current) -> Int? {
        guard let date, let day = calendar.date(from: date) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: day)).day
    }
}

/// Un esame nel calendario: il nodo, la data, i nodi collegati.
public struct ExamEntry: Sendable, Equatable, Identifiable {
    public var node: NodeRecord
    public var info: ExamInfo
    public var linked: [UUID]
    public var id: UUID { node.id }

    /// Esami attivi in ordine di data (senza data in fondo), con i nodi vicini nel grafo.
    public static func calendar(nodes: [NodeRecord], edges: [EdgeRecord], calendar: Calendar = .current) -> [ExamEntry] {
        let exams = nodes.filter { $0.type == .exam && $0.deletedAt == nil }
        let live = edges.filter { $0.deletedAt == nil }
        let entries = exams.map { exam -> ExamEntry in
            let linked = live.compactMap { edge -> UUID? in
                if edge.sourceID == exam.id { return edge.targetID }
                if edge.targetID == exam.id { return edge.sourceID }
                return nil
            }
            return ExamEntry(node: exam, info: ExamInfo.parse(exam.tags), linked: Array(Set(linked)))
        }
        return entries.sorted { a, b in
            switch (a.info.date.flatMap(calendar.date(from:)), b.info.date.flatMap(calendar.date(from:))) {
            case let (x?, y?): return x != y ? x < y : a.node.title < b.node.title
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.node.title < b.node.title
            }
        }
    }
}
