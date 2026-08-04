import Foundation

/// Names the events card does not draw, because they happened to everybody.
///
/// **This exists because no structural signal could do the job.** Measured on a
/// real device: 49 of 77 surviving events were Hong Kong and US public holidays,
/// and every one of them was `all_day=1`, not recurring, with no organiser and no
/// url — which is character for character what "Outpatient", "Marco's arrival"
/// and "1st email" look like in the same calendar. Nothing in the shape of the
/// row separates them.
///
/// The calendar-level test cannot reach them either. `CalendarDistiller.isGenerated`
/// drops a calendar *named* for holidays, and catches Apple's `US Holidays` and
/// `香港节假日`; these are the same days copied into somebody's own primary
/// calendar by Google, where they are ordinary events in an ordinary calendar.
///
/// **A reading, not a filter on what is kept.** Every one of these rows is still
/// collected, still synced and still reaches the ontology stage — the standing
/// rule is that if it can be distilled it is distilled. A public holiday is
/// simply not a fact about the person: they did not choose Christmas.
///
/// **Matched by token rather than by whole name, which is the whole design.**
/// Google writes the same day a dozen ways — "New Year's Day observed", "First
/// Weekday After Christmas Day", "Second Day of Lunar New Year", "Day after
/// Mid-Autumn Festival" — and an exact-name list would need every variant of
/// every holiday and would still miss the next one. One token catches the family.
///
/// **It is incomplete and always will be**, which is why it is the last test
/// rather than the only one. It covers the two regions this dataset comes from
/// and the observances that travel; a phone in Berlin or São Paulo keeps its
/// holidays. That is the acceptable failure — the alternative is a rule broad
/// enough to swallow a real event, and losing somebody's trip costs more than
/// showing them Karneval.
enum PublicHolidays {

    static func matches(_ title: String) -> Bool {
        let name = title.lowercased()
        return terms.contains { name.contains($0) }
    }

    /// Lowercased, matched as substrings. Apostrophes are avoided in the tokens
    /// wherever possible: calendars are inconsistent between `'` and `’`, and
    /// "new year" catches both while "new year's" catches one.
    private static let terms: [String] = [
        // — Hong Kong and Chinese, the ones this calendar actually carried
        "lunar new year", "chinese new year", "spring festival",
        "tomb sweeping", "ching ming", "qingming",
        "buddha",                       // Buddha's Birthday, and the day following
        "dragon boat", "tuen ng",
        "mid-autumn", "mid autumn",
        "hungry ghost",
        "chung yeung", "double ninth",
        "national day of the people",   // narrow: "national day" alone is too broad
        "hong kong special administrative region establishment",
        "winter solstice",

        // — Christian and Western observances, which travel
        "christmas", "boxing day",
        "new year",                     // covers Eve, Day, and "observed"
        "good friday", "holy saturday", "easter", "ash wednesday", "palm sunday",
        "all saints", "all souls",
        "halloween", "hallowe'en",
        "valentine",
        "st patrick", "saint patrick",
        "april fool",
        "mother's day", "mothers day", "mothering sunday",
        "father's day", "fathers day",
        "labour day", "labor day",
        "hanukkah", "chanukah", "kwanzaa",
        "yom kippur", "rosh hashanah", "passover", "purim", "sukkot",
        "eid al", "ramadan", "diwali", "vesak",

        // — United States federal and observed
        "independence day", "fourth of july", "july 4th",
        "thanksgiving",
        "memorial day", "veterans day", "armistice day",
        "presidents day", "president's day", "washington's birthday",
        "martin luther king", "mlk day",
        "columbus day", "indigenous peoples",
        "juneteenth",
        "flag day", "groundhog day", "cinco de mayo",
        "election day", "inauguration day",
        "daylight saving", "daylight savings",

        // — United Kingdom and Commonwealth, cheap to include
        "bank holiday", "boxing day", "remembrance sunday",
        "guy fawkes", "bonfire night",

        // — Chinese-script forms, since this calendar is bilingual
        "節日", "节日", "假期", "公眾假期", "公众假期", "春節", "春节",
        "中秋", "端午", "清明", "重陽", "重阳", "聖誕", "圣诞", "元旦",
    ]
}
