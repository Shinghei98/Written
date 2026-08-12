import Foundation

/// Phase 3's read of the semantic pipeline: the owner's own assertions.
///
/// **Everything this calls already existed.** `0048` built the whole narrow-RPC
/// surface §8 asks for — `api.list_assertions`, `confirm_assertion`,
/// `add_assertion`, `suppress_assertion`, `restore_assertion` and
/// `record_assertion_exposure` — every one `security definer` and scoped to
/// `auth.uid()`. Phase 3 is pointing the app at them, not building them.
///
/// **Owner-only, structurally.** These are the *reader's own* assertions and
/// there is no parameter for whose: the functions take `auth.uid()` from the
/// token. A function that let a caller name the subject would be a function for
/// reading somebody else's profile, which is what `discovery_cards` exists to
/// do narrowly and under its own rules.
///
/// **Two switches, and they are not redundant.**
/// `AppConfig.semanticSurfacesEnabled` decides whether the app asks at all;
/// `memories_reads` decides whether the server answers. The first is a build
/// decision and ships with the binary; the second is §9's rollback contract —
/// *"a runtime feature flag can return the app to legacy non-semantic product
/// operation"* — and can be thrown without an App Store release. A disabled
/// surface answers `42501` from `assert_surface_allowed`, which this reads as
/// "off" rather than as an error, because a flag being down is a decision
/// somebody made and not a fault to report.
actor SemanticSurfaceService {

    static let shared = SemanticSurfaceService()

    /// One assertion as the app draws it.
    ///
    /// **`label` is the ontology's preferred label, not the source's string.**
    /// That is the difference between this and the legacy Memories page: there,
    /// every term is a raw artist or channel name; here it is a concept
    /// somebody could disagree with by name. `displayState` is the person's own
    /// answer — `default`, `confirmed` or `suppressed` — and comes back on the
    /// same row so the page never has to ask twice.
    struct Assertion: Identifiable, Sendable {
        let id: UUID
        let predicate: String
        let label: String
        let origin: String
        let displayState: String
        let strength: Double?
        let confidence: Double?
        let scoreVersionID: UUID?

        var isConfirmed: Bool { displayState == "confirmed" }
        var isSuppressed: Bool { displayState == "suppressed" }
        /// Whether the machine claimed this or the person added it themselves.
        /// Worth drawing differently: one is a reading of somebody's data and
        /// the other is a statement they made.
        var isInferred: Bool { origin == "inferred" }

        /// The same assertion with a different answer on it, for drawing a tap
        /// before the server has agreed to it — and for putting the old answer
        /// back when it refuses.
        func settingDisplayState(_ state: String) -> Assertion {
            Assertion(
                id: id, predicate: predicate, label: label, origin: origin,
                displayState: state, strength: strength, confidence: confidence,
                scoreVersionID: scoreVersionID
            )
        }
    }

    private(set) var lastError: String?

    /// Which surfaces the server has switched on.
    ///
    /// **Read rather than assumed, and cached for nothing.** `api.feature_flags`
    /// is the one function not gated behind a surface — gating the answer to
    /// "which surfaces are on" behind a surface being on would make it
    /// unobtainable exactly when it is needed — and it already folds in
    /// `emergency_privacy_kill_switch`, so a single call gives both the flag and
    /// the master stop.
    func enabledSurfaces() async -> Set<String> {
        guard AppConfig.semanticSurfacesEnabled else { return [] }
        do {
            let rows = try await PostgREST.callFunction("feature_flags")
            let enabled = rows.compactMap { row -> String? in
                guard (row["enabled"] as? Bool) == true else { return nil }
                return row["flag_key"] as? String
            }
            lastError = nil
            return Set(enabled)
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    /// The owner's assertions, or `nil` for *could not ask*.
    ///
    /// **`nil` rather than `[]`, which is this codebase's standing defect stated
    /// as a return type.** An empty array here would draw a Memories page
    /// reading "nothing yet" over a network failure or a signed-out session, and
    /// eleven instances of exactly that are recorded in `CLAUDE.md`. A caller
    /// gets `if let` or nothing.
    ///
    /// A **disabled surface answers `[]`, not `nil`** — the server was reached
    /// and it declined, which is a real answer and the one the legacy path
    /// should be drawn for.
    func assertions() async -> [Assertion]? {
        guard AppConfig.semanticSurfacesEnabled else { return [] }
        do {
            let rows = try await PostgREST.callFunction("list_assertions")
            lastError = nil
            return rows.compactMap(Self.assertion(from:))
        } catch let error as PostgREST.Failure {
            // **Matched on the message, not on `42501` alone**, and the
            // difference is not pedantry. `assert_surface_allowed` raises
            // `insufficient_privilege` for a surface whose flag is down — but
            // so does *"permission denied for schema api"*, which is what an
            // unexposed schema or a missing grant answers, and so does every
            // row-level-security refusal in the project.
            //
            // Keying on the code alone would read a real permission failure as
            // "the surface is switched off" and quietly draw the legacy page
            // forever. Seen for real while testing the exposure: the same
            // `42501` came back for a reason that had nothing to do with a
            // flag.
            if case .server(_, let code, let message) = error,
               code == "42501", message.contains("is disabled") {
                lastError = nil
                return []
            }
            lastError = error.localizedDescription
            return nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Answering an assertion, which is what makes Phase 3 different from the
    /// legacy page.
    ///
    /// **Assertion-specific, per §8, and that is the whole point.** Striking a
    /// term off Memories today goes through `BanList.Kind` and removes *every
    /// row whose name matches* — so banning an artist also bans a channel of
    /// the same name, and the ban is keyed to a string rather than to a claim.
    /// These four name one assertion by id, so "I do not like this" and "this
    /// is not me" stop being the same act. The contract is explicit that a
    /// title ban must never become a concept-level negative.
    /// **Every answer is anchored to what was on screen, and the schema insists.**
    /// `suppress_assertion` and its siblings end with
    /// *"matching assertion exposure is required"* — an answer must name the
    /// exposure it is answering, so "I disagree" refers to a particular label at
    /// a particular rank computed by a particular score version, rather than to
    /// a concept in the abstract. A score that has since moved cannot silently
    /// inherit somebody's rejection of an older one.
    ///
    /// The first version of this passed `NSNull()` for the exposure and never
    /// called this function at all, so **every confirm and suppress failed** —
    /// found not by a test but by the owner tapping remove and asking whether
    /// it had stuck. It had not.
    ///
    /// **Recorded at the moment of the answer, not when the card draws.** The
    /// row demonstrably was on screen — somebody just pressed it — so the
    /// anchoring is honest either way, and recording one per row per visit would
    /// be 36 round trips for a page most people will only read. The cost is that
    /// `assertion_exposures` cannot answer *"what was shown and not acted on"*,
    /// which is a shadow metric §10 asks for and which wants display-time
    /// recording when somebody builds it.
    private func exposure(
        for assertion: Assertion, rank: Int, surface: String
    ) async -> String? {
        do {
            let rows = try await PostgREST.callFunction("record_assertion_exposure", arguments: [
                "p_target_assertion_id": assertion.id.uuidString.lowercased(),
                // `NSNull` and a `String?` have no common type, so the
                // optional is widened explicitly rather than coalesced.
                "p_assertion_score_version_id":
                    assertion.scoreVersionID.map { $0.uuidString.lowercased() as Any }
                        ?? (NSNull() as Any),
                "p_presentation_version": Self.presentationVersion,
                "p_displayed_label": assertion.label,
                "p_rank": rank,
                "p_surface_name": surface,
            ])
            guard let exposureID = rows.first?["value"] as? String, !exposureID.isEmpty else {
                // **A successful request whose answer could not be read is its
                // own failure**, and saying so is what separates it from a
                // refusal. Silence here is what made the exposure bug look like
                // the server rejecting an answer it had never been asked.
                lastError = "The server accepted the request and returned no exposure id."
                return nil
            }
            lastError = nil
            return exposureID
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// What the reader was looking at when they answered. Bumped when the card's
    /// layout changes enough that an old answer was about a different thing.
    static let presentationVersion = "memories-assertions-v1"

    @discardableResult
    func confirm(_ assertion: Assertion, rank: Int, surface: String = "memories") async -> Bool {
        await answer("confirm_assertion", assertion, rank: rank, surface: surface)
    }

    @discardableResult
    func suppress(_ assertion: Assertion, rank: Int, surface: String = "memories") async -> Bool {
        await answer("suppress_assertion", assertion, rank: rank, surface: surface)
    }

    /// **Restore takes no exposure, and that is the schema being right.**
    /// `restore_assertion` has three parameters where its siblings have four:
    /// a suppressed assertion is filtered out of `list_assertions`, so it was
    /// never on screen, so there is no exposure it could be answering. Routing
    /// it through the same path as confirm and suppress — which the first
    /// version did — sends an argument the function does not declare.
    ///
    /// The consequence for the app is larger than the signature: **there is no
    /// way to list what somebody has hidden.** Nothing returns suppressed
    /// assertions, so restoration is reachable only in the moment, as an undo,
    /// and a row hidden last week cannot be brought back from this surface at
    /// all. That wants a second RPC rather than a client change, and it is a
    /// decision about what a person is owed rather than a missing function.
    @discardableResult
    func restore(_ assertion: Assertion, surface: String = "memories") async -> Bool {
        await call("restore_assertion", [
            "p_target_assertion_id": assertion.id.uuidString.lowercased(),
            "p_client_event_id": UUID().uuidString.lowercased(),
            "p_surface_name": surface,
        ])
    }

    private func answer(
        _ name: String, _ assertion: Assertion, rank: Int, surface: String
    ) async -> Bool {
        guard let exposureID = await exposure(for: assertion, rank: rank, surface: surface) else {
            // `lastError` is already set by `exposure`. Returning false here is
            // what puts the row back on screen — an answer the server never
            // recorded must not stay looking recorded.
            return false
        }
        return await call(name, [
            "p_target_assertion_id": assertion.id.uuidString.lowercased(),
            "p_client_event_id": UUID().uuidString.lowercased(),
            "p_exposure_id": exposureID,
            "p_surface_name": surface,
        ])
    }

    /// **A `client_event_id` on every write, and it is not decoration.**
    /// `feedback_events` is keyed on it so a retried tap is one event rather
    /// than two — the same idempotence the ingestion path gets from its
    /// fingerprint. Generated per call here because each tap is its own event;
    /// a stored one would make a second tap a duplicate of the first.
    private func call(_ name: String, _ arguments: [String: Any]) async -> Bool {
        guard AppConfig.semanticSurfacesEnabled else { return false }
        do {
            _ = try await PostgREST.callFunction(name, arguments: arguments)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    #if DEBUG
    /// `-probe-surface` → read the owner's assertions through the real RPCs and
    /// say what came back.
    ///
    /// ```
    /// xcrun simctl launch <device> com.written.datingapp -probe-surface 1
    /// ```
    ///
    /// **The one link nobody can exercise without a signed-in device.** Each
    /// piece of Phase 3's read path has been checked on its own — `authenticated`
    /// has usage on `api` and execute on all seven functions, the schema is
    /// exposed (confirmed by a request that resolved only with
    /// `Content-Profile: api`), and `0103` proves the flag gates the guard. None
    /// of that proves a token Supabase actually minted reaches
    /// `api.list_assertions` and comes back with *this person's* rows. A
    /// simulator holds no session, so run it there and it correctly reports
    /// being signed out — which exercises the wiring and nothing past it.
    ///
    /// **It reads and never writes.** Confirm and suppress are somebody's own
    /// answers about themselves, and a probe that recorded one to test a
    /// network call would be putting words in their mouth. That is the
    /// difference from `-probe-ingest`, which must write because the write path
    /// is what it exists to prove.
    ///
    /// It deliberately does *not* bypass the flags. The interesting failure
    /// here is a surface that is off, and a probe that reached around the guard
    /// would prove a path the app never takes.
    func probe() async -> String {
        guard AppConfig.semanticSurfacesEnabled else {
            return "AppConfig.semanticSurfacesEnabled is false: this build never asks."
        }

        let flags = await enabledSurfaces()
        var lines = ["flags on: " + (flags.isEmpty ? "none" : flags.sorted().joined(separator: ", "))]
        if let failure = lastError {
            lines.append("feature_flags failed: \(failure)")
        }

        guard let found = await assertions() else {
            return (lines + ["list_assertions: could not ask — \(lastError ?? "no reason given")"])
                .joined(separator: "\n")
        }

        if found.isEmpty {
            lines.append(
                flags.contains("memories_reads")
                    ? "list_assertions: reached, and returned nothing."
                    : "list_assertions: the server declined — memories_reads is off, "
                      + "which is the surface guard working."
            )
            return lines.joined(separator: "\n")
        }

        let confirmed = found.filter(\.isConfirmed).count
        let suppressed = found.filter(\.isSuppressed).count
        lines.append("\(found.count) assertion(s), \(confirmed) confirmed, \(suppressed) suppressed")
        for assertion in found.prefix(5) {
            let strength = assertion.strength.map { String(format: "%.3f", $0) } ?? "—"
            lines.append("  \(assertion.label) · \(strength) · \(assertion.displayState)")
        }
        if found.count > 5 { lines.append("  … and \(found.count - 5) more") }
        return lines.joined(separator: "\n")
    }
    #endif

    private static func assertion(from row: [String: Any]) -> Assertion? {
        guard let idText = row["assertion_id"] as? String,
              let id = UUID(uuidString: idText),
              let label = row["label"] as? String, !label.isEmpty
        else { return nil }
        return Assertion(
            id: id,
            predicate: row["predicate_key"] as? String ?? "",
            label: label,
            origin: row["origin"] as? String ?? "inferred",
            displayState: row["display_state"] as? String ?? "default",
            strength: row["strength"] as? Double,
            confidence: row["confidence"] as? Double,
            scoreVersionID: (row["assertion_score_version_id"] as? String)
                .flatMap(UUID.init(uuidString:))
        )
    }
}
