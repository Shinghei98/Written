import Foundation

/// Publishes *this* user into the discovery pool.
///
/// **The half of discovery that was never built.** `DiscoveryService` reads
/// `discovery_cards`; `tools/seed_synthetic.py` writes six of them with the
/// secret key; and nothing in the app ever wrote one. So the six synthetic
/// accounts were discoverable and every real person who signed up was invisible
/// — reported as "I could not find the new test accounts in the discovery page",
/// which is exactly right and was never a bug in the feed.
///
/// The policies for this were in `0007` from the start: `own row` for insert and
/// `own row update` for update, both `auth.uid() = user_id`. Only the caller was
/// missing.
///
/// **What goes in the card is the security argument, not a convenience.** The
/// migration's header is explicit that this table must never become a view over
/// `distilled_records`: a domain and a subject are what `Ontology.line` needs to
/// write a sentence, so a domain and a subject are all that travel. No item ids,
/// no titles of songs or videos or events, no counts, no timestamps. Anything
/// added here is readable by every signed-in user of the app, which is true of
/// nothing else in this schema.
actor DiscoveryCardService {

    static let shared = DiscoveryCardService()

    private(set) var lastError: String?

    /// Everything the card needs, gathered on the main actor by the caller —
    /// this actor does no reading of app state, so there is one place to look
    /// when asking what leaves the device.
    struct Card {
        let displayName: String
        let age: Int?
        let district: String?
        /// `source` is what the subject was distilled from, and it is carried
        /// for retention rather than for display. A YouTube channel and an
        /// Apple Music artist are classified through the same ontology and can
        /// land in the same domain, so `domain` cannot tell them apart — and
        /// YouTube's terms cap its data at 30 days while Apple Music's have no
        /// such rule. Sweeping on domain would either keep what must go or
        /// destroy what may stay. See `0016_youtube_retention.sql`.
        let interests: [(domain: String, subject: String, source: String)]
        /// Object paths in `profile-photos`, in the order the person arranged
        /// them. **Empty means this person is not shown at all** — see `publish`.
        let photoPaths: [String]
        /// The ontology mix, ranked — what the dynamic profile's three bars
        /// draw. Computed by `Ontology.mix`, which is Swift, which is why this
        /// travels on the card rather than being worked out in SQL.
        ///
        /// **A domain, never a subject.** "Music" says less about somebody than
        /// the artist names already in `interests`, so this widens nothing;
        /// the school and the bio, which do, go through `match_profile()`
        /// instead and never touch this table.
        var domains: [(domain: String, share: Double)] = []
    }

    /// Writes the row, creating it the first time and updating it after.
    ///
    /// `merge-duplicates` is safe here: `0009` is the only migration that
    /// revokes update, and it does not touch this table — so the upsert's
    /// `on conflict do update` has the privileges it needs on every column.
    /// (`likes`, `conversations` and `messages` are the ones where this compiles
    /// to a 42501 and `ignore-duplicates` is required instead.)
    @discardableResult
    func publish(_ card: Card) async -> Bool {
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = "Not signed in."
            return false
        }
        // **After the token, never before.** The refresh is what fills the id in
        // on a cold launch; reading it first reports "not signed in" for a
        // session that is merely not restored yet.
        guard let userID = await SupabaseAuth.shared.userID else {
            lastError = "No account id."
            return false
        }

        // **No photographs, no card.** A profile with no face is not a profile
        // — the feed would draw a name and two interest lines over blank space —
        // so somebody who skipped the photo page simply is not in the pool until
        // they add one. Publishing an empty card and filtering it on read would
        // put the same decision two round trips further from where it is made.
        guard !card.photoPaths.isEmpty else {
            lastError = nil
            return false
        }

        let body: [String: Any] = [
            "user_id": userID,
            "display_name": card.displayName,
            "age": card.age as Any,
            "district": card.district as Any,
            // `photo_seeds` is deliberately not written any more. It was six
            // integers driving generated placeholder portraits, which made every
            // real account look photographed when none of them were. The column
            // stays for the six synthetic accounts, whose seeds the seeder
            // wrote and whose faces do not exist as files.
            "photo_paths": card.photoPaths,
            "interests": card.interests.map {
                ["domain": $0.domain, "subject": $0.subject, "source": $0.source]
            },
            "domains": card.domains.map {
                ["domain": $0.domain, "share": $0.share]
            },
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]

        var request = URLRequest(url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/discovery_cards"))
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                // PostgREST's own words. The silent-failure lesson from the
                // biographics work: a push that returns false without saying
                // why sends the next person to check their signal.
                lastError = String(data: data, encoding: .utf8) ?? "Discovery card failed (\(status))."
                return false
            }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Removes this account's card, which is the whole of "pause".
    ///
    /// **A delete rather than a flag on the row**, because a flag would need a
    /// migration, a policy that still lets others read the row, and every
    /// reader to remember to check it. `DiscoveryService` reads this table and
    /// nothing else, so an absent row is already understood by everything
    /// downstream — and `0007` has carried an own-row delete policy from the
    /// start.
    ///
    /// Nothing is lost by it. The card is derived: `publish` rebuilds it from
    /// the distillation and the photographs whenever the user unpauses or
    /// distils again.
    ///
    /// Built with `URLComponents` for the reason `SyncService.delete` records —
    /// `appendingPathComponent` escapes the `?`, and a DELETE that loses its
    /// filter is the worst possible version of this call. Here RLS would still
    /// confine it to one row, which is the second reason the policies matter.
    @discardableResult
    func withdraw() async -> Bool {
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = "Not signed in."
            return false
        }
        guard let userID = await SupabaseAuth.shared.userID else {
            lastError = "No account id."
            return false
        }

        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/discovery_cards"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "user_id", value: "eq.\(userID)")]
        guard let url = components?.url else {
            lastError = "Could not form the request."
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                lastError = String(data: data, encoding: .utf8) ?? "Could not pause (\(status))."
                return false
            }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

}
