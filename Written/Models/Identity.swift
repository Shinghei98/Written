import Foundation

/// How somebody describes themselves, asked once during onboarding.
///
/// **A set, not a single value, and that is the whole reason this exists
/// separately from `users.sex`.** That column is one `text` and was written by
/// the dashboard's gender row; a person who is more than one of these had
/// nowhere to say so. The set is joined with `|` on the way to the column, in
/// the same grammar `DistilledRecord.extra` uses for its lists, so the column
/// keeps working and the answer stops being lossy.
///
/// **Distinct from `DatingPreferences.genders`**, which is who they want to
/// *see*. The two share a vocabulary and answer different questions, and
/// collapsing them is the mistake this file is arranged to prevent.
enum Identity {

    /// Account-scoped, for the reason every other store here is: a gender left
    /// behind on a shared phone would greet whoever signed in next.
    private static var key: String { AccountScope.key("written.identity.genders") }

    static var genders: Set<DatingPreferences.Gender> {
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(stored.compactMap(DatingPreferences.Gender.init(rawValue:)))
    }

    static func save(_ genders: Set<DatingPreferences.Gender>) {
        UserDefaults.standard.set(genders.map(\.rawValue), forKey: key)
    }

    // MARK: - Birthday

    /// The birthday, as the day itself rather than an age.
    ///
    /// **Local, and only ever read to know whether the question has been
    /// asked.** `public.users.birth_date` is the record and `IdentitySummary`
    /// is what the app draws; this exists because the launch route has to be
    /// decided on the first frame, before any of that has been fetched — the
    /// same reason `restoredStep` exists at all.
    private static var birthdayKey: String { AccountScope.key("written.identity.birthday") }

    static var birthday: Date? {
        let stored = UserDefaults.standard.double(forKey: birthdayKey)
        return stored == 0 ? nil : Date(timeIntervalSince1970: stored)
    }

    static func save(birthday: Date) {
        UserDefaults.standard.set(birthday.timeIntervalSince1970, forKey: birthdayKey)
    }

    /// Whether a date of birth clears the floor the Terms have always stated.
    ///
    /// **Here rather than in the view model**, because two screens enforce it
    /// and only one of them can reach a view model: the onboarding page runs
    /// two screens ahead of `AppShell`. `DistillViewModel.minimumAge` is the
    /// number; this is the test.
    static func age(on birthday: Date, asOf now: Date = Date()) -> Int? {
        Calendar.current.dateComponents([.year], from: birthday, to: now).year
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: birthdayKey)
    }

    /// What goes in `users.sex`. Declaration order rather than set order, so the
    /// column does not churn between launches for somebody who picked two.
    static func columnValue(_ genders: Set<DatingPreferences.Gender>) -> String {
        DatingPreferences.Gender.allCases
            .filter(genders.contains)
            .map(\.label)
            .joined(separator: "|")
    }
}
