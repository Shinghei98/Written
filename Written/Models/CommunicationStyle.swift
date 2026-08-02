import Foundation

/// How someone wants to be approached, asked once during onboarding.
///
/// Two sliders, and both are **continuous to the finger and categorical to
/// everything else**. Nobody can honestly place themselves at 0.62 of a flirt,
/// and a number that precise invites a matching algorithm to believe it. So the
/// travel is divided into quarters and only the quarter is the answer; the exact
/// position is kept alongside it purely so the slider can be put back where it
/// was left, which is a drawing concern rather than a fact about the person.
enum StyleBand {

    /// Four bands, so this is what "dividing the bar into 4" means everywhere.
    static let count = 4

    /// Which band a 0...1 position falls in.
    ///
    /// The right-hand edge belongs to the last band. Without the clamp a
    /// position of exactly 1.0 indexes a fifth band that does not exist — and a
    /// slider dragged hard to the end is the single most likely input here.
    static func index(for fraction: Double) -> Int {
        min(count - 1, max(0, Int(fraction * Double(count))))
    }

    /// The middle of a band, for drawing a value that was stored as a category.
    ///
    /// The exact position is remembered too, but only on the device that set it.
    /// Anything restored from Postgres has the band and nothing else, so the
    /// gauge needs somewhere sensible to point.
    static func fraction(of index: Int) -> Double {
        (Double(index) + 0.5) / Double(count)
    }
}

/// How forward the user is willing to be, from `Low` to `Extremely High`.
///
/// **Two vocabularies on purpose.** The `rawValue` is the flat internal one that
/// gets stored and will one day be compared between two people; `word` is what
/// the dashboard shows. "Freaky" is a good thing to read about yourself on your
/// own profile and a poor thing to sort a database by.
enum FlirtLevel: String, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case extremelyHigh = "Extremely High"

    var word: String {
        switch self {
        case .low: return "Platonic"
        case .medium: return "Mild"
        case .high: return "Flirty"
        case .extremelyHigh: return "Freaky"
        }
    }

    init(fraction: Double) {
        self = Self.allCases[StyleBand.index(for: fraction)]
    }

    /// Where the gauge points when all that survived was the band.
    var fraction: Double {
        StyleBand.fraction(of: Self.allCases.firstIndex(of: self) ?? 0)
    }
}

/// How quickly they answer, named as tempi.
///
/// Musical terms rather than "slow" and "fast" because the honest answer is
/// about *tendency*, and a tempo marking is already understood to be a
/// disposition rather than a promise. The sentence underneath is what actually
/// sets the expectation.
enum ResponseTime: String, CaseIterable {
    case largo = "Largo"
    case andante = "Andante"
    case allegro = "Allegro"
    case prestissimo = "Prestissimo"

    var note: String {
        switch self {
        case .largo: return "Can't reply quickly, sorry."
        case .andante: return "Reply sporadically."
        case .allegro: return "Maybe within a day."
        case .prestissimo: return "Fast replies."
        }
    }

    init(fraction: Double) {
        self = Self.allCases[StyleBand.index(for: fraction)]
    }

    var fraction: Double {
        StyleBand.fraction(of: Self.allCases.firstIndex(of: self) ?? 0)
    }
}

/// Both answers together, which is how they are asked and how they are stored.
struct CommunicationStyle: Equatable {
    var flirt: FlirtLevel
    var response: ResponseTime

    /// Slider positions, for restoring the control rather than describing the
    /// person. See the note on `StyleBand`.
    var flirtPosition: Double
    var responsePosition: Double

    /// The middle of the bar on both, which is a real answer rather than a
    /// refusal to give one — `Medium` and `Allegro`.
    static let unset = CommunicationStyle(
        flirt: .medium, response: .allegro,
        flirtPosition: 0.5, responsePosition: 0.5
    )
}

/// Where the answers live between the page that collects them and the app.
///
/// **Not `RecordStore`, and not the view model.** This page runs *before*
/// `AppShell` exists, so there is no `DistillViewModel` to put them in yet —
/// the same problem the photo page has, which `RootView` solves by holding the
/// array itself. That works for photos because nothing else needs them; these
/// two are also the thing that decides whether the page gets asked again, so
/// they have to outlive the launch rather than the screen.
///
/// Keyed by account, like every other store here: signing out must not hand the
/// next person the last one's answers, and signing back in must return them.
enum CommunicationStyleStore {

    private static var key: String { AccountScope.key("written.communication.style") }

    static var saved: CommunicationStyle? {
        guard let raw = UserDefaults.standard.dictionary(forKey: key),
              let flirt = (raw["flirt"] as? String).flatMap(FlirtLevel.init(rawValue:)),
              let response = (raw["response"] as? String).flatMap(ResponseTime.init(rawValue:))
        else { return nil }
        return CommunicationStyle(
            flirt: flirt,
            response: response,
            // Fall back to the band's midpoint: a dictionary written by an
            // older build, or one rebuilt from the server, has the category and
            // no position.
            flirtPosition: raw["flirtPosition"] as? Double ?? flirt.fraction,
            responsePosition: raw["responsePosition"] as? Double ?? response.fraction
        )
    }

    static func save(_ style: CommunicationStyle) {
        UserDefaults.standard.set(
            [
                "flirt": style.flirt.rawValue,
                "response": style.response.rawValue,
                "flirtPosition": style.flirtPosition,
                "responsePosition": style.responsePosition,
            ],
            forKey: key
        )
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
