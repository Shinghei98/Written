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
        /// The hub this term sits under, and the heading a person reads.
        ///
        /// **Both, because one of them is not enough.** `blockKey` is the
        /// stable identifier to group and sort on; `blockLabel` is the words —
        /// returning only the key would put `hub:ideas_learning` on screen or
        /// make this file hold a second copy of the labels, which is the drift
        /// the ontology exists to prevent.
        ///
        /// `nil` where nobody authored a parent. Four of one account's channels
        /// are deliberately unplaced, because a term in the wrong block is a
        /// false claim about somebody where an unblocked one is merely
        /// unsorted — so this must be drawn as its own group rather than
        /// dropped.
        let blockKey: String?
        let blockLabel: String?

        var isConfirmed: Bool { displayState == "confirmed" }
        var isSuppressed: Bool { displayState == "suppressed" }

        /// Whether the person does this or watches it, where the evidence said.
        ///
        /// **`nil` is the ordinary answer and must stay drawable.** Every
        /// assertion in the database today is `affinity_to`, which says only
        /// *this person likes this* — the engagement predicates are written by
        /// the scorer when the evidence is marked `participation` or
        /// `spectating`, and most evidence is marked neither. A saved track is
        /// not watching or doing anything.
        ///
        /// The words are short because they sit beside a term rather than
        /// replacing it: the row still says *Soccer*, and this says which
        /// soccer. Deliberately not "Plays" and "Watches" — one is a sport's
        /// word and the other a screen's, and this has to read as well of
        /// pottery and the flute as of football.
        var engagement: String? {
            switch predicate {
            case "participates_in_activity": return "Does"
            case "follows_activity": return "Follows"
            default: return nil
            }
        }
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
                scoreVersionID: scoreVersionID,
                blockKey: blockKey, blockLabel: blockLabel
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
    /// Whether the scores behind the page are still catching up.
    ///
    /// **A blank page and a recalculating page are the same picture**, and the
    /// difference matters to the person looking at it. `list_assertions`
    /// withholds every inferred assertion whose score predates the account's
    /// current revision — right, because the alternative is showing numbers the
    /// system no longer stands behind — so a distillation empties the page until
    /// the worker catches up. Zero rows cannot say which of those it is; this
    /// can.
    ///
    /// `nil` for *could not ask*, never `false`. Answering false on a dropped
    /// request would draw "you have nothing" over an account that is merely
    /// mid-recompute, which is the exact confusion this exists to end.
    func isRecomputing() async -> Bool? {
        guard AppConfig.semanticSurfacesEnabled else { return false }
        do {
            let rows = try await PostgREST.callFunction("memories_status")
            lastError = nil
            guard let row = rows.first,
                  let recomputing = row["recomputing"] as? Bool else { return nil }
            return recomputing
        } catch {
            return nil
        }
    }

    /// Retires every inferred claim and redacts YouTube's captured payloads.
    /// `nil` on success, a reason on failure.
    ///
    /// **The half of *Disconnect all* that never existed.** That control calls
    /// `SyncService.deleteEverything`, which empties four tables in `public` and
    /// names none of the ones Memories reads — so the blocks stayed on the page
    /// after every source had been disconnected, drawn from a vault the button
    /// had never reached. Reported 2026-08-14, and it reads as the control not
    /// working.
    ///
    /// **Not gated on `semanticSurfacesEnabled`, unlike every other call
    /// here.** That flag decides whether the app *asks* for the Memories page;
    /// the assertions exist either way, and a read switch that also disabled
    /// somebody's erasure would be a retention decision wearing a feature
    /// flag's clothes. Erasure has to work on the worst day.
    ///
    /// **A reason, not a `Bool`.** The caller draws it: an erasure that failed
    /// silently would leave a person believing their terms were gone while the
    /// page still lists them, which is the same failure the legacy half already
    /// reports through `saveError`.
    func forgetDistillation() async -> String? {
        do {
            _ = try await PostgREST.callFunction("forget_distillation")
            lastError = nil
            return nil
        } catch {
            lastError = error.localizedDescription
            return error.localizedDescription
        }
    }

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
    /// Something the person says about themselves, which no phone observed.
    ///
    /// **Free text rather than a concept id, and the RPC takes exactly one.**
    /// `add_assertion` refuses both or neither — *"provide exactly one existing
    /// concept or new label"* — and a label is the right one here: somebody
    /// adding "Hilary Hahn" should not have to find her concept id, and the
    /// resolver's vocabulary is not a thing a person can browse. A term with no
    /// concept becomes a `user_term`, which is exactly what `0108`'s kind filter
    /// keeps: it has no `concept_kind` to allow, so the rule is written as
    /// *"a user's own term or an allowed kind"*.
    ///
    /// **No exposure**, for the same reason `restore` needs none: nothing was
    /// shown, so there is nothing this could be answering. It is a statement
    /// rather than a reply.
    @discardableResult
    /// A term somebody typed, attached to the vocabulary where it matches it.
    ///
    /// **`add_assertion` has always accepted either a concept or a label, and
    /// this only ever sent the label.** So every typed term became a
    /// `user_term`: a private string with no concept, no kind and no block,
    /// unrelated to the identical concept the machine may already assert about
    /// the same person. Typing `Hearthstone` produced a second, unconnected row.
    ///
    /// The lookup is exact and server-side. A miss is the ordinary case and
    /// falls through to the free label, which is exactly today's behaviour —
    /// nothing a person types can be refused because the ontology has not heard
    /// of it.
    ///
    /// `blockKey` is a hint for disambiguation and cannot move a term: the
    /// ontology decides where a concept lives, and a tap on a card is not an
    /// argument about that.
    func add(
        _ label: String,
        blockKey: String? = nil,
        surface: String = "memories"
    ) async -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let concept = await motherConcept(for: trimmed, blockKey: blockKey)
        return await call("add_assertion", [
            "p_client_event_id": UUID().uuidString.lowercased(),
            "p_target_concept_id": concept.map { $0 as Any } ?? NSNull(),
            // **Exactly one of the two, which the server enforces.**
            // `add_assertion` raises on `num_nonnulls(...) <> 1`, so sending
            // both would refuse the addition outright.
            "p_new_label": concept == nil ? trimmed : NSNull(),
            "p_linked_observation_ids": [String](),
            "p_surface_name": surface,
        ])
    }

    /// The concept a typed term names, or `nil` when the ontology has not heard
    /// of it.
    ///
    /// **A failed lookup is not a failed addition.** Anything other than a
    /// confident match returns `nil` and the caller adds the term as its own
    /// string, so an outage or an unexposed schema costs the link rather than
    /// the term — and `lastError` is deliberately left alone, because the
    /// person's action succeeded.
    private func motherConcept(for text: String, blockKey: String?) async -> String? {
        do {
            let rows = try await PostgREST.callFunction("resolve_term_for_addition", arguments: [
                "p_text": text,
                "p_block_key": blockKey.map { $0 as Any } ?? NSNull(),
            ])
            guard let first = rows.first,
                  let id = first["concept_id"] as? String else { return nil }
            return id
        } catch {
            return nil
        }
    }

    // MARK: - Suggested Memories (the calibration review surface)

    /// A term the model proposed and the owner has not yet judged. Distinct
    /// from an `Assertion` on purpose: a suggestion is a question, an
    /// assertion is an answer, and drawing them from one type is how a page
    /// starts implying a suggestion is already true.
    struct Suggestion: Identifiable, Sendable {
        let id: UUID          // review_item_id — the immutable proposal revision
        let label: String
        let kind: String      // the proposal's family/kind, as the server names it
        let tier: String
        let rank: Int
        let struck: Bool
        let conceptID: UUID?
        let provisionalID: UUID?
    }

    /// The owner's pending suggestions, `nil` for *could not ask*. An empty
    /// array is a real answer (nothing to review, or the surface's flag is
    /// down for this account); nil is a network or server failure and the
    /// caller must not redraw an empty state over a cached one.
    func suggestions() async -> [Suggestion]? {
        guard AppConfig.semanticSurfacesEnabled else { return [] }
        do {
            let rows = try await PostgREST.callFunction(
                "begin_calibration", arguments: ["batch_size": 8])
            lastError = nil
            guard let envelope = rows.first?["value"] as? [String: Any],
                  let items = envelope["items"] as? [[String: Any]] else {
                // A bare `{epoch, items: []}` with no items parses here too.
                return []
            }
            return items.compactMap { item in
                guard let idString = item["review_item_id"] as? String,
                      let id = UUID(uuidString: idString),
                      let label = item["label"] as? String else { return nil }
                return Suggestion(
                    id: id,
                    label: label,
                    kind: item["predicate"] as? String ?? "",
                    tier: item["confidence_tier"] as? String ?? "",
                    rank: item["rank"] as? Int ?? 0,
                    struck: item["struck"] as? Bool ?? false,
                    conceptID: (item["concept_id"] as? String).flatMap(UUID.init),
                    provisionalID: (item["provisional_entity_id"] as? String).flatMap(UUID.init)
                )
            }
        } catch let error as PostgREST.Failure {
            // Same reading as `assertions()`: a downed flag answers 42501
            // with "is disabled", and only that pair means "switched off".
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

    /// Keep: the decision that authorizes catalogue minting. The server
    /// records the immutable positive event and creates exactly one mint
    /// request; everything after that (mint, scoring, the Memory appearing)
    /// is the pipeline's job, never this button's.
    @discardableResult
    func keep(_ suggestion: Suggestion) async -> Bool {
        await call("keep_calibration_item", [
            "p_review_item_id": suggestion.id.uuidString.lowercased(),
        ])
    }

    @discardableResult
    func strike(_ suggestion: Suggestion) async -> Bool {
        // The older verbs take `item`, the newer take `p_review_item_id`;
        // each call names what its function's signature actually says.
        await call("strike_calibration_item", [
            "item": suggestion.id.uuidString.lowercased(),
        ])
    }

    @discardableResult
    func restoreSuggestion(_ suggestion: Suggestion) async -> Bool {
        await call("restore_calibration_item", [
            "item": suggestion.id.uuidString.lowercased(),
        ])
    }

    /// Edit: the original proposal is recorded as negative model feedback and
    /// the correction proceeds under the owner's own words.
    @discardableResult
    func editSuggestion(_ suggestion: Suggestion,
                        label: String, family: String) async -> Bool {
        await call("edit_calibration_item", [
            "p_review_item_id": suggestion.id.uuidString.lowercased(),
            "p_label": label,
            "p_family": family,
        ])
    }

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
                .flatMap(UUID.init(uuidString:)),
            blockKey: row["block_key"] as? String,
            blockLabel: row["block_label"] as? String
        )
    }
}
