import Foundation

/// Who the user wants to be shown, and how far away they may be.
///
/// **Nothing reads these yet, and that is not a reason to store them loosely.**
/// There is no matcher: Explore shows whoever has a card. These exist so that
/// the day one is written, the answers are already there for everybody who has
/// been using the app — a preference asked for after the fact has already
/// missed the people who set it.
///
/// Stored like `CommunicationStyle`: account-scoped `UserDefaults` for the
/// device, and `user` records for the server. That is the pattern this codebase
/// settled on for anything that owns no column — it applies locally at once
/// rather than waiting on a round trip, because nothing here can be *refused*
/// by Postgres the way an age or a name can.
struct DatingPreferences: Equatable {

    /// Who to show. Not who the user is — `users.sex` is that, and the two are
    /// deliberately different questions.
    enum Gender: String, CaseIterable, Identifiable {
        case men
        case women
        case nonbinary
        case everyone

        var id: String { rawValue }

        var label: String {
            switch self {
            case .men: return "Men"
            case .women: return "Women"
            case .nonbinary: return "Nonbinary people"
            case .everyone: return "Everyone"
            }
        }
    }

    var gender: Gender = .everyone

    /// Miles. The bar runs 1 to 100 and the value is the whole answer — there
    /// is no "anywhere", because a dating app that quietly means the world is
    /// not answering the question it asked.
    var radiusMiles: Int = 25

    /// Both ends, inclusive. 18 is a floor rather than a default: below it this
    /// is not a product that should return anybody.
    var minAge: Int = 18
    var maxAge: Int = 45

    /// Hidden from Explore. **Not hidden from people already talking to them** —
    /// see `SettingsModel.setPaused`, which withdraws the discovery card and
    /// touches nothing else.
    var isPaused: Bool = false

    static let ageFloor = 18
    static let ageCeiling = 80
    static let radiusFloor = 1
    static let radiusCeiling = 100
}

/// The device's copy, keyed per account.
///
/// `AccountScope.key` is what stops one person's preferences greeting the next
/// person to sign in on the same phone — the same reason every other store here
/// is scoped rather than global.
enum DatingPreferencesStore {

    private static var key: String { AccountScope.key("written.dating.preferences") }

    static var saved: DatingPreferences? {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else { return nil }
        var preferences = DatingPreferences()
        if let gender = (raw["gender"] as? String).flatMap(DatingPreferences.Gender.init(rawValue:)) {
            preferences.gender = gender
        }
        // Each field falls back to its default independently rather than the
        // whole dictionary being rejected: a build that adds a fifth preference
        // must not discard the four somebody already set.
        if let radius = raw["radiusMiles"] as? Int { preferences.radiusMiles = radius }
        if let minAge = raw["minAge"] as? Int { preferences.minAge = minAge }
        if let maxAge = raw["maxAge"] as? Int { preferences.maxAge = maxAge }
        if let paused = raw["isPaused"] as? Bool { preferences.isPaused = paused }
        return preferences
    }

    static func save(_ preferences: DatingPreferences) {
        UserDefaults.standard.set(
            [
                "gender": preferences.gender.rawValue,
                "radiusMiles": preferences.radiusMiles,
                "minAge": preferences.minAge,
                "maxAge": preferences.maxAge,
                "isPaused": preferences.isPaused,
            ],
            forKey: key
        )
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
