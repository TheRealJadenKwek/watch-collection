import Foundation

@main
enum WearTotalsTests {
    static func main() throws {
        let today = "2026-09-04"
        let yesterday = "2026-09-03"
        let older = WearSession(id: "older", date: yesterday, durationMinutes: 75)
        let first = WearSession(id: "morning", date: today, durationMinutes: 180)

        let fiveHours = try WearTotals.settingTotal(in: [older, first], on: today, totalMinutes: 300)
        try expect(fiveHours == [older, WearSession(id: first.id, date: today, durationMinutes: 300)],
                   "Changing three hours to five must save five, preserving the original ID and other day")
        let fiveHoursAgain = try WearTotals.settingTotal(in: fiveHours, on: today, totalMinutes: 300)
        try expect(fiveHoursAgain == fiveHours, "Saving five hours again must be idempotent")

        let reduced = try WearTotals.settingTotal(in: fiveHours, on: today, totalMinutes: 120)
        try expect(reduced == [older, WearSession(id: first.id, date: today, durationMinutes: 120)],
                   "Reducing a day's total must replace its duration")
        let cleared = try WearTotals.settingTotal(in: reduced, on: today, totalMinutes: 0)
        try expect(cleared == [older], "Zero must clear only the selected day")
        let clearedAgain = try WearTotals.settingTotal(in: cleared, on: today, totalMinutes: 0)
        try expect(clearedAgain == cleared, "Clearing an empty day must leave the array unchanged")

        let evening = WearSession(id: "evening", date: today, durationMinutes: 120)
        let anotherDay = WearSession(id: "older-second", date: yesterday, durationMinutes: 45)
        let multiple = [first, older, evening, anotherDay]
        let unchangedMultiple = try WearTotals.settingTotal(in: multiple, on: today, totalMinutes: 300)
        try expect(unchangedMultiple == multiple,
                   "An unchanged total must preserve every session, ID, and array position exactly")
        let consolidated = try WearTotals.settingTotal(in: multiple, on: today, totalMinutes: 360)
        try expect(consolidated == [WearSession(id: first.id, date: today, durationMinutes: 360), older, anotherDay],
                   "Changed multi-session days must consolidate using the first ID without moving unrelated entries")
        let clearedMultiple = try WearTotals.settingTotal(in: multiple, on: today, totalMinutes: 0)
        try expect(clearedMultiple == [older, anotherDay], "Zero must clear all selected-day sessions")

        let minimum = try WearTotals.settingTotal(in: [older], on: today, totalMinutes: 15)
        try expect(minimum.count == 2 && minimum[0] == older && minimum[1].date == today && minimum[1].durationMinutes == 15,
                   "A previously empty day must accept 15 minutes")
        let minimumAgain = try WearTotals.settingTotal(in: minimum, on: today, totalMinutes: 15)
        try expect(minimumAgain == minimum, "A newly inserted session must keep its ID when saved again")
        let maximum = try WearTotals.settingTotal(in: minimum, on: today, totalMinutes: 1440)
        try expect(maximum[1].durationMinutes == 1440 && maximum[1].id == minimum[1].id,
                   "A day must accept the 24-hour boundary")
        let emptyZero = try WearTotals.settingTotal(in: [], on: today, totalMinutes: 0)
        try expect(emptyZero.isEmpty, "Zero must not create a session")

        for invalid in [Int.min, -15, -1, 1, 14, 1441, Int.max] {
            do {
                _ = try WearTotals.settingTotal(in: multiple, on: today, totalMinutes: invalid)
                throw Failure(description: "Accepted invalid duration: \(invalid)")
            } catch WearTotalError.invalidMinutes {
                // Expected: invalid totals do not produce a mutated collection.
            }
        }

        print("WearTotals tests passed: replacements, idempotence, reduction, clearing, session preservation, and duration bounds.")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }
}
