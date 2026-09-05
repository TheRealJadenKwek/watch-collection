import Foundation

enum WearTotalError: Error {
    case invalidMinutes
}

enum WearTotals {
    /// Sets a day's total while preserving the other days and any unchanged sessions.
    /// The caller supplies normalized sessions, including any legacy wear dates.
    static func settingTotal(
        in sessions: [WearSession],
        on day: String,
        totalMinutes: Int
    ) throws -> [WearSession] {
        guard totalMinutes == 0 || (15...1440).contains(totalMinutes) else {
            throw WearTotalError.invalidMinutes
        }

        let matching = sessions.filter { $0.date == day }
        guard matching.reduce(0, { $0 + $1.durationMinutes }) != totalMinutes else {
            return sessions
        }

        guard totalMinutes > 0 else {
            return sessions.filter { $0.date != day }
        }

        let replacement = WearSession(
            id: matching.first?.id ?? UUID().uuidString.lowercased(),
            date: day,
            durationMinutes: totalMinutes
        )
        var result: [WearSession] = []
        var replaced = false
        for session in sessions {
            if session.date != day {
                result.append(session)
            } else if !replaced {
                result.append(replacement)
                replaced = true
            }
        }
        if !replaced { result.append(replacement) }
        return result
    }
}
