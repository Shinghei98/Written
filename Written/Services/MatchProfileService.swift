import Foundation

/// The dynamic profile: everything one match may see about another.
///
/// **Two reads, split by how identifying the field is.** The card carries the
/// name, age, district, photographs, subjects and the ontology mix, and is
/// readable by any signed-in account. The school and the bio are not on it and
/// never will be — those come from `match_profile()`, a `security definer`
/// function that answers only somebody holding an invitation from this person
/// or a conversation with them. See `0037`.
///
/// So the access rule lives in Postgres rather than in which buttons exist. A
/// page reachable from two places is a drawing; a function that returns no rows
/// is a rule.
actor MatchProfileService {

    static let shared = MatchProfileService()

    /// What the viewer brings to the comparison: their own subjects and their
    /// own domains, both already lowercased for matching.
    ///
    /// Passed in rather than read here, because it lives on `DistillViewModel`
    /// and this actor deliberately reads no app state — the same rule
    /// `DiscoveryCardService.Card` follows, so there is one place to look when
    /// asking what leaves the device.
    struct Viewer {
        let subjects: Set<String>
        let domains: Set<String>
    }

    struct Profile: Equatable {
        let personID: String
        let name: String
        let age: Int?
        let school: String?
        let district: String?
        let bio: String?
        let photoPaths: [String]
        /// Ranked. Read by the caption fallback rather than drawn — see
        /// `topSubjects` for what the three figures actually show.
        let domains: [Ontology.Weight]
        /// The three named things the page draws where posts / followers /
        /// following sit. Fewer than three when somebody has fewer; padding it
        /// out would invent breadth.
        let topSubjects: [Ontology.SubjectWeight]
        /// One per photograph, positionally. `nil` where there was nothing true
        /// to say — see `captions(theirs:viewer:count:)`.
        let captions: [String?]
        /// The same gated ingredients the feed composes from — served by
        /// `match_card` out of `matching_terms`, so this page and the
        /// discovery card cannot drift apart.
        let terms: [DiscoveryService.BioTerm]
    }

    private(set) var lastError: String?

    /// **Returns nil for "could not ask", never an empty profile.** A page that
    /// drew a blank name and no photographs would read as the person having
    /// deleted themselves.
    func profile(for personID: String, viewer: Viewer) async -> Profile? {
        guard let me = await SupabaseAuth.shared.currentUserID(), me != personID else {
            lastError = "You're not signed in."
            return nil
        }

        do {
            // The card and the gated half together — they are independent, and
            // waiting for one before asking for the other is a round trip on
            // the screen somebody is already staring at.
            // **`match_card`, not a direct read of `discovery_cards`.** That
            // table's policy is *any signed-in user may read it*, so the card
            // half of this page consulted nothing: `0123` hid a blocked
            // person's school and bio and left their name and face. `0126`
            // puts both halves behind one condition — `private.may_see_match`
            // — so the two cannot disagree about who may see this profile.
            //
            // Unconditional, with no feature flag: the discovery flag decides
            // whether the *feed* is server-owned, while this is an
            // authorisation hole that exists today, and gating the fix on a
            // rollout would be choosing to leave it open.
            async let cardRows = PostgREST.insert(
                "rest/v1/rpc/match_card",
                body: ["target": personID],
                prefer: "return=representation"
            )
            async let gatedRows = PostgREST.insert(
                "rest/v1/rpc/match_profile",
                body: ["target": personID],
                prefer: "return=representation"
            )

            guard let card = try await cardRows.first,
                  let name = (card["display_name"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else {
                // No card is a real answer: somebody with no photographs is
                // never published. Nothing to draw, and nothing went wrong.
                lastError = nil
                return nil
            }

            // **A refusal here is not a failure.** `match_profile` returns zero
            // rows both for "you may not ask" and for "they filled in neither
            // field", deliberately — see the migration. Either way the page
            // simply omits those two lines.
            let gated = (try? await gatedRows.first) ?? [:]

            let theirSubjects = (card["interests"] as? [[String: Any]] ?? [])
                .compactMap { $0["subject"] as? String }
            let theirDomains: [Ontology.Weight] = (card["domains"] as? [[String: Any]] ?? [])
                .compactMap { row in
                    guard let raw = row["domain"] as? String,
                          let domain = Ontology.Domain(rawValue: raw)
                    else { return nil }
                    return Ontology.Weight(
                        domain: domain,
                        share: (row["share"] as? NSNumber)?.doubleValue ?? 0
                    )
                }

            // The three figures the page draws. Ranked and already capped by
            // the device that wrote them, so this trusts the order rather than
            // re-sorting: `Ontology.subjects` breaks ties on the name so the
            // same library always produces the same row, and re-sorting here on
            // share alone would undo that.
            let theirTopSubjects: [Ontology.SubjectWeight] =
                (card["top_subjects"] as? [[String: Any]] ?? [])
                .compactMap { row in
                    guard let subject = (row["subject"] as? String)?.nonEmptyValue
                    else { return nil }
                    return Ontology.SubjectWeight(
                        subject: subject,
                        share: (row["share"] as? NSNumber)?.doubleValue ?? 0
                    )
                }

            let paths = card["photo_paths"] as? [String] ?? []
            // The composed dynamic bio, the owner's direction (2026-08-28):
            // the six photographs read as six cards carrying the same lines
            // the discovery page draws. Same decode as `DiscoveryService`,
            // same composer, same mutuality snapshot — the legacy overlap
            // captions below survive only as the never-invent fallback for
            // a person whose terms compose to nothing.
            let terms: [DiscoveryService.BioTerm] =
                (card["terms"] as? [[String: Any]] ?? [])
                .compactMap { term in
                    guard let label = term["label"] as? String
                    else { return nil }
                    return DiscoveryService.BioTerm(
                        label: label,
                        kind: term["kind"] as? String,
                        score: (term["score"] as? Double)
                            ?? (term["score"] as? NSNumber)?.doubleValue
                            ?? 1.0,
                        category: DiscoveryService.BioCategory(wire: term["category"] as? String),
                        hub: term["hub"] as? String,
                        block: term["block"] as? String
                    )
                }
            let composed = BioComposer.compose(
                viewer: await BioComposer.viewerSnapshot(), terms: terms)
            lastError = nil
            return Profile(
                personID: personID,
                name: name,
                age: (card["age"] as? NSNumber)?.intValue,
                school: (gated["school"] as? String)?.nonEmptyValue,
                district: (card["district"] as? String)?.nonEmptyValue,
                bio: (gated["bio"] as? String)?.nonEmptyValue,
                photoPaths: paths,
                // Kept whole and no longer drawn as the triple: the caption
                // fallback below is `Domain.sharedLine`, which needs them.
                domains: theirDomains,
                // Three, matching the reference's posts / followers / following.
                topSubjects: theirTopSubjects,
                captions: composed.isEmpty
                    ? Self.captions(
                        theirSubjects: theirSubjects,
                        theirDomains: theirDomains,
                        viewer: viewer,
                        count: paths.count
                      )
                    : (0..<paths.count).map { index in
                        index < composed.count ? composed[index].text : nil
                      },
                terms: terms
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// One caption per photograph, degrading as the overlap runs out.
    ///
    /// **Subjects first, then domains, then nothing.** Two real libraries share
    /// one or two specific things and almost never six, so captioning every
    /// photo with a subject would mean inventing five of them. The fallback is
    /// the *domain*, which is still true and still about both people — it just
    /// says less. When even that runs out the photograph carries no caption,
    /// because a commonality that does not exist is the one thing this whole
    /// feature must not manufacture.
    ///
    /// Each is used once. Repeating "You both listen to Ado" under three
    /// photographs makes a thin overlap look thinner than it is.
    static func captions(
        theirSubjects: [String],
        theirDomains: [Ontology.Weight],
        viewer: Viewer,
        count: Int
    ) -> [String?] {
        guard count > 0 else { return [] }

        var lines: [String] = []
        var used: Set<String> = []

        for subject in theirSubjects where lines.count < count {
            let key = subject.lowercased()
            guard viewer.subjects.contains(key), !used.contains(key) else { continue }
            used.insert(key)
            lines.append("You both like \(subject).")
        }

        for weight in theirDomains where lines.count < count {
            let key = weight.domain.rawValue.lowercased()
            guard viewer.domains.contains(key), !used.contains(key) else { continue }
            used.insert(key)
            lines.append(weight.domain.sharedLine)
        }

        // Padded with nils rather than truncated: the array is positional, so
        // photograph four keeps its own slot whether or not it has a line.
        return (0..<count).map { $0 < lines.count ? lines[$0] : nil }
    }

    #if DEBUG
    /// `-probe-match <user-uuid>` → call `match_profile` on somebody and report
    /// it beside the authorisation you actually hold over them.
    ///
    /// ```
    /// xcrun simctl launch <device> com.written.datingapp -probe-match <uuid>
    /// ```
    ///
    /// **The RPC's answer alone proves nothing, and that is deliberate in the
    /// function rather than a shortcoming here.** `match_profile` returns zero
    /// rows for a refusal *and* for a match who filled in neither field,
    /// because distinguishing them would tell a caller whether an account
    /// exists. So a probe that only reported "0 rows" could never separate
    /// `0122` working from the target having an empty profile — which is
    /// exactly the ambiguity that made the first attempt to test `0122` on a
    /// device prove nothing.
    ///
    /// The second half is what makes it readable: the like and conversation
    /// rows between the two people, which the caller may read under their own
    /// RLS without any special privilege. Put together:
    ///
    ///     rows 0, like from them `declined`   -> refused. 0122 working.
    ///     rows 0, like from them `pending`    -> a bug, or an empty profile.
    ///     rows 1                              -> authorised, and they filled
    ///                                            something in.
    ///
    /// **For an unambiguous read, probe somebody who has a school or a bio.**
    /// Against an empty profile the first two lines cannot be told apart, and
    /// no amount of reporting here fixes that — the information is not the
    /// caller's to have.
    func probe(target: String) async -> String {
        guard let me = await SupabaseAuth.shared.currentUserID() else {
            return "no access token: you're signed out. A simulator holds no "
                 + "session, so run this on a device."
        }
        if me == target {
            return "target is you: match_profile returns early on me = target."
        }

        var lines: [String] = ["me:     \(me)", "target: \(target)"]

        do {
            let rows = try await PostgREST.insert(
                "rest/v1/rpc/match_profile",
                body: ["target": target],
                prefer: "return=representation"
            )
            if let row = rows.first {
                let school = (row["school"] as? String)?.nonEmptyValue ?? "—"
                let bio = (row["bio"] as? String)?.nonEmptyValue ?? "—"
                lines.append("match_profile: 1 row (school: \(school), bio: \(bio))")
            } else {
                lines.append("match_profile: 0 rows")
            }
        } catch {
            lines.append("match_profile: failed — \(error.localizedDescription)")
        }

        // The authorisation half. Both directions, because which one authorises
        // is the whole question: only a like *from* the target counts.
        let likes = (try? await PostgREST.rows("rest/v1/likes", query: [
            "or": "(and(liker_id.eq.\(me),liked_id.eq.\(target)),"
                + "and(liker_id.eq.\(target),liked_id.eq.\(me)))",
            "select": "liker_id,status",
        ])) ?? []

        if likes.isEmpty {
            lines.append("likes: none either way")
        } else {
            for like in likes {
                let from = (like["liker_id"] as? String) == me ? "you -> them" : "them -> you"
                let status = (like["status"] as? String) ?? "?"
                lines.append("like \(from): \(status)"
                    + ((like["liker_id"] as? String) == target && status == "declined"
                       ? "   <- 0122: this must NOT authorise" : ""))
            }
        }

        let conversations = (try? await PostgREST.rows("rest/v1/conversations", query: [
            "or": "(and(user_a.eq.\(me),user_b.eq.\(target)),"
                + "and(user_a.eq.\(target),user_b.eq.\(me)))",
            "select": "id",
        ])) ?? []
        lines.append("conversation: \(conversations.isEmpty ? "none" : "exists — authorises regardless of the like")")

        return lines.joined(separator: "\n")
    }
    #endif
}

private extension String {
    var nonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if DEBUG
extension MatchProfileService.Profile {
    /// A filled-in profile for `-chat profile`.
    ///
    /// Six photographs, three domains and a caption list that **runs out on
    /// purpose** — two shared subjects, then two shared domains, then two
    /// photographs with nothing true to say. That degradation is the part most
    /// likely to be wrong and the part a real pair will hit immediately, so the
    /// sample exercises it rather than showing six neat captions.
    static let sample = MatchProfileService.Profile(
        personID: "sample-Ines",
        name: "Inés",
        age: 27,
        school: "HKU | HKUST",
        district: "Sai Ying Pun, Hong Kong",
        bio: "Mostly out by the water",
        photoPaths: (0..<6).map { "sample/\($0).jpg" },
        domains: [
            .init(domain: .music, share: 0.46),
            .init(domain: .playedSport, share: 0.31),
            .init(domain: .travel, share: 0.14),
        ],
        // One short name, one long one and one in between, because the long
        // ones are what break this row — a classical performer's credit runs to
        // sixty characters in a column a third of the screen wide.
        topSubjects: [
            .init(subject: "Ado", share: 0.22),
            .init(subject: "Johann Sebastian Bach", share: 0.14),
            .init(subject: "English Baroque Soloists, Monteverdi Choir & John Eliot Gardiner",
                  share: 0.11),
        ],
        captions: [
            "You both like Ado.",
            "You both like Fujii Kaze.",
            Ontology.Domain.playedSport.sharedLine,
            Ontology.Domain.travel.sharedLine,
            nil,
            nil,
        ]
    )
}
#endif
