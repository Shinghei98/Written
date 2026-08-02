import Foundation

/// How long ago, in the shortest form that is still unambiguous.
///
/// `RelativeDateTimeFormatter` is the obvious tool and produces the wrong thing:
/// "3 hours ago" beside a name is longer than the name. This is the scheme the
/// design asks for — hours inside a day, days inside a month, and a plain date
/// after that, because "47d" is a number nobody converts.
///
/// Below an hour it says minutes rather than `0h`, which is the one liberty taken
/// with the spec: a like from twenty minutes ago reading as zero hours old looks
/// like a bug in the timestamp.
enum RelativeTime {

    /// Beyond this, an exact date is more use than a count of days.
    private static let daysBeforeExactDate = 30

    static func short(since date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)

        // A clock that disagrees with the server's, or a row written a moment in
        // the future. "now" is the honest answer and it costs nothing.
        guard seconds > 60 else { return "now" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < daysBeforeExactDate { return "\(days)d" }

        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? thisYear : otherYear).string(from: date)
    }

    /// The same clock, said in words, for the line under a name in a chat header.
    ///
    /// A separate function rather than a parameter on `short`, because the two
    /// have opposite jobs. `short` sits at the end of a crowded row and must not
    /// be longer than the name beside it, so it says "3h". This has a line to
    /// itself under the name and is read as a sentence, where "3h" is curt and
    /// slightly cryptic.
    ///
    /// The buckets are the ones the design asks for: now, inside the hour,
    /// hours, days, and a plain date once a month has passed.
    static func lastSeen(since date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds > 60 else { return "now" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "less than an hour ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s") ago" }

        let days = hours / 24
        if days < daysBeforeExactDate { return "\(days) day\(days == 1 ? "" : "s") ago" }

        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? thisYear : otherYear).string(from: date)
    }

    /// The wall-clock time a message was sent, as "2:04 PM".
    ///
    /// **In the reader's time zone, not the sender's.** `DateFormatter` defaults
    /// to the device's current zone, and the `Date` it is handed came from a
    /// `timestamptz` — an absolute instant — so a message sent at nine in Seoul
    /// reads as whatever nine in Seoul was where you are standing. That is the
    /// behaviour wanted and it falls out of doing nothing, which is worth
    /// stating so nobody later "fixes" it by pinning a zone.
    ///
    /// A literal `h:mm a` rather than `setLocalizedDateFormatFromTemplate`,
    /// which the rest of this file uses. The template form is normally right —
    /// it lets a locale choose its own order — but it would also give a 24-hour
    /// clock wherever that is the convention, and AM/PM was asked for
    /// specifically. The symbols themselves still localise.
    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    /// "12 Mar" while it is still this year, "12 Mar 2025" once it is not —
    /// carrying the year on everything would make the common case noisier for the
    /// sake of the rare one.
    ///
    /// `setLocalizedDateFormatFromTemplate` rather than a literal `dateFormat`, so
    /// a locale that writes the month first gets its own order.
    private static let thisYear = formatter(template: "d MMM")
    private static let otherYear = formatter(template: "d MMM y")

    private static func formatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
