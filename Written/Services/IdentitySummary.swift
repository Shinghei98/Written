import Foundation

/// The three facts a profile leads with: how old, which sex, and where.
///
/// Read off records like everything else on the dashboard, so it exports with
/// the rest of the distillation and needs no store of its own. Any of the three
/// may be missing — Health's characteristics are declinable one by one, and
/// location is a separate permission again — and a missing one means a row that
/// simply isn't drawn.
struct IdentitySummary: Equatable {
    var age: Int?
    var sex: String?
    /// "Shibuya, Tokyo" — district and city, never a coordinate.
    var place: String?
    /// Every school, as the person typed it. One string rather than a list:
    /// nothing downstream parses it yet, and splitting it here would invent a
    /// separator the user never agreed to.
    var education: String?
    var occupation: String?

    /// The two onboarding sliders. Stored as their internal band names, so a
    /// record round-trips through Postgres as text like everything else here.
    var flirtLevel: FlirtLevel?
    var responseTime: ResponseTime?

    /// Deliberately **not** widened to include the two sliders.
    ///
    /// This asks "is there anything to say about this person yet", and the
    /// sliders always have an answer — everyone leaves onboarding with a band.
    /// Counting them would make it permanently true and the question pointless.
    var isEmpty: Bool {
        age == nil && sex == nil && place == nil && education == nil && occupation == nil
    }

    static func summary(in records: [DistilledRecord]) -> IdentitySummary {
        var summary = IdentitySummary()
        /// Kept apart so they can win: a birthday or a gender the user typed in
        /// is a correction of whatever Health had, and a correction that loses
        /// to the thing it corrects is no correction at all. Gender especially —
        /// Health answers a different question (biological sex) and only one of
        /// the two was actually asked of the user.
        var enteredAge: Int?
        var enteredSex: String?

        for record in records where !record.isRemovedByUser {
            switch (record.source, record.dataType) {
            case ("health", "age"): summary.age = Int(record.name)
            case ("user", "age"): enteredAge = Int(record.name)
            case ("health", "biological_sex"): summary.sex = record.name
            case ("user", "gender"): enteredSex = record.name
            case ("location", "place"): summary.place = record.name
            // No `health` counterpart to lose to, so these need none of the
            // entered-wins machinery above — only the user can know them.
            case ("user", "education"): summary.education = record.name
            case ("user", "occupation"): summary.occupation = record.name
            // Unknown text means a band this build doesn't have — a record
            // written by a later version, or a hand-edited row. Left `nil`
            // rather than guessed at, so the card simply doesn't draw.
            case ("user", "flirt_level"): summary.flirtLevel = FlirtLevel(rawValue: record.name)
            case ("user", "response_time"): summary.responseTime = ResponseTime(rawValue: record.name)
            default: continue
            }
        }

        summary.age = enteredAge ?? summary.age
        summary.sex = enteredSex ?? summary.sex
        return summary
    }
}
