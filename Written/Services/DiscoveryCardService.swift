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
        let interests: [(domain: String, subject: String)]
        /// Object paths in `profile-photos`, in the order the person arranged
        /// them. **Empty means this person is not shown at all** — see `publish`.
        let photoPaths: [String]
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
            "interests": card.interests.map { ["domain": $0.domain, "subject": $0.subject] },
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

}
