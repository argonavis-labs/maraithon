import Foundation

enum AppFormatters {
    static let shortDate: Date.FormatStyle = .dateTime.month(.abbreviated).day().year(.defaultDigits)

    /// Foundation formatter construction is expensive and these run on every
    /// row render, so build each once. Formatters are safe to share for
    /// formatting as long as they are not mutated after setup.
    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = Locale.current.currency?.identifier ?? "USD"
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private nonisolated(unsafe) static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func currencyString(for value: Decimal) -> String {
        currencyFormatter.string(from: value as NSDecimalNumber) ?? "$0"
    }

    static func relativeString(for date: Date, relativeTo referenceDate: Date = Date()) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: referenceDate)
    }

    static func chatTimeString(for date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func chatDayString(
        for date: Date,
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: referenceDate) {
            return "Today"
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: referenceDate),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }

        return date.formatted(shortDate)
    }
}
