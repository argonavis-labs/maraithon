import Foundation

enum AppFormatters {
    static let shortDate: Date.FormatStyle = .dateTime.month(.abbreviated).day().year(.defaultDigits)

    static func currencyString(for value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = Locale.current.currency?.identifier ?? "USD"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: value as NSDecimalNumber) ?? "$0"
    }

    static func relativeString(for date: Date, relativeTo referenceDate: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: referenceDate)
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

        return date.formatted(.dateTime.month(.abbreviated).day().year(.defaultDigits))
    }
}
