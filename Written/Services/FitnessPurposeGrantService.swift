import Foundation

/// Whether this account has agreed to fitness data being captured, and the one
/// place that agreement is recorded.
///
/// **HealthKit is fail-closed in the vault and this is the only door.**
/// `guard_raw_healthkit_grant` refuses an active HealthKit row unless
/// `semantic_private.healthkit_use_grants` holds an active grant for that
/// person. Without one, every HealthKit batch is refused — and
/// `SemanticIngestionService` treats a refusal as permanent and drops it, so the
/// data would disappear quietly rather than failing loudly. Asking first is the
/// difference between not sending and losing.
///
/// **HealthKit's own permission sheet is not this.** That one asks iOS for
/// *access*; this asks the person what the data may be *used for*, which is a
/// different question with a different answer and its own version string. The
/// v0.3.1 contract wants HealthKit transfer gated on a recorded
/// `fitness_connection` purpose grant, and this is that record.
///
/// **What Phase 1 asks for is the least it can.** Any active grant permits raw
/// retention; the four booleans gate matching, bios and icebreakers, and all
/// four are sent false — *keep and use my activity to describe me to myself,
/// and nothing else*. Widening that is a new consent question rather than a
/// default to flip.
actor FitnessPurposeGrantService {

    static let shared = FitnessPurposeGrantService()

    /// The wording somebody agreed to. **Bump it when the sheet's words
    /// change**, or the record says they agreed to something they never read.
    static let consentVersion = "fitness-v1"

    /// Cached per account, so a distillation does not need a round trip before
    /// it can decide whether to send. `AccountScope` keys it, for the reason
    /// every other store here is keyed: a grant is one person's answer.
    private static var cacheKey: String { AccountScope.key("written.fitness.grant") }

    /// What the device last knew. `nil` means never asked *on this device* —
    /// which is not the same as "no grant", since the server is the record.
    private(set) var isGranted: Bool? {
        get { UserDefaults.standard.object(forKey: Self.cacheKey) as? Bool }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: Self.cacheKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.cacheKey) }
        }
    }

    /// Record the agreement. Returns the reason it could not be, or `nil`.
    ///
    /// **Only called after somebody has actually agreed.** The subject is
    /// `auth.uid()` server-side and cannot be named by this call, which is the
    /// point: a function that let a caller say whose consent it was recording
    /// would be a function for forging consent.
    func record() async -> String? {
        do {
            _ = try await PostgREST.insert(
                "rest/v1/rpc/record_fitness_grant",
                body: [
                    "allow_fitness_matching": false,
                    "allow_bio_naming": false,
                    "allow_icebreaker_naming": false,
                    "allow_controlled_explanation": false,
                    "consent_version": Self.consentVersion,
                ],
                prefer: "return=representation"
            )
            isGranted = true
            return nil
        } catch {
            // **Not cached as `false` on a failure.** "The network was down"
            // and "they said no" are different facts, and writing the second
            // when the first happened would leave somebody permanently
            // unasked-and-refused with nothing to correct it.
            return error.localizedDescription
        }
    }

    /// Ask the server, and remember the answer.
    ///
    /// `nil` for *could not ask* — the shape this codebase settled on after
    /// `paths()` answering `[]` for a dropped request drew every saved
    /// photograph as unsaved. A caller must be able to tell "no grant" from "no
    /// answer", because the first means do not send and the second means try
    /// again later.
    @discardableResult
    func refresh() async -> Bool? {
        do {
            let rows = try await PostgREST.insert(
                "rest/v1/rpc/has_fitness_grant",
                body: [String: String](),
                prefer: "return=representation"
            )
            // A scalar-returning RPC comes back as a bare value rather than a
            // row, which PostgREST wraps differently depending on the call.
            let granted = (rows.first?["has_fitness_grant"] as? Bool)
                ?? (rows.first?.values.first as? Bool)
            guard let granted else { return nil }
            isGranted = granted
            return granted
        } catch {
            return nil
        }
    }

    /// Wired into `DistillViewModel.signOutLocalState`, like every other
    /// per-account store: the next person to use this phone must be asked
    /// rather than inherit an answer.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }
}
