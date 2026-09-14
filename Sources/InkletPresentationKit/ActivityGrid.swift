import Foundation

/// Sunday-aligned calendar cells shared by the Widget and its previews.
public enum ActivityGrid {
    public static func columns(counts: [Date: Int], date: Date, weeks: Int = 26,
                               calendar: Calendar = .current) -> [[Int?]] {
        guard weeks > 0 else { return [] }
        let today = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: today)
        guard let sunday = calendar.date(byAdding: .day, value: -(weekday - 1), to: today),
              let start = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: sunday) else { return [] }
        return (0..<weeks).map { week in
            (0..<7).map { offset in
                guard let day = calendar.date(byAdding: .day, value: week * 7 + offset, to: start),
                      day <= today else { return nil }
                return max(0, counts[day] ?? 0)
            }
        }
    }

    public static func total(counts: [Date: Int], date: Date, calendar: Calendar = .current) -> Int {
        columns(counts: counts, date: date, calendar: calendar).flatMap { $0 }.compactMap { $0 }.reduce(0, +)
    }
}
