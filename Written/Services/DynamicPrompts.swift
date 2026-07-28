import Foundation

/// The same profile, written differently for whoever is reading it.
///
/// This is **dynamic prompting** — the second of Written's two ideas, and the
/// one distillation exists to serve. A static bio says the same thing to a
/// stranger and to someone who shares your taste; these don't. If a reader is
/// deep in Mandopop, the Mandopop is what surfaces first.
///
/// Every line here is assembled from figures the distillation actually produced.
/// Nothing is invented: a person's profile shouldn't contain sentences they
/// never earned, and a preview that flatters with made-up detail teaches the
/// wrong thing about what the product does.
enum DynamicPrompts {

    struct Prompt: Identifiable {
        var id: String { viewer }
        /// Who this rendering is for.
        let viewer: String
        /// The line that leads, because this reader shares it.
        let lead: String
        /// What sits under it, when there is more to say.
        let support: String?
        let artwork: [URL]
        let symbol: String
    }

    /// At most three, in the order the branches unlock. A facet with nothing
    /// behind it is left out rather than filled with a placeholder.
    static func previews(
        artists: [MusicHighlights.Artist],
        genres: [MusicHighlights.Genre],
        channels: [MediaHighlights.Channel],
        chronotype: LifestyleHighlights.Chronotype?,
        sports: [LifestyleHighlights.Sport]
    ) -> [Prompt] {
        var prompts: [Prompt] = []

        if let top = artists.first {
            // The genre is the better description of a *reader* — "someone who
            // loves Mandopop" is a kind of person, where "someone who loves Jay
            // Chou" is nearly the same person — so it leads when we have one.
            let affinity = genres.first.map(\.name) ?? top.name
            let others = artists.dropFirst().prefix(2).map(\.name)
            prompts.append(
                Prompt(
                    viewer: "Someone who loves \(affinity)",
                    lead: "\(top.songs) \(top.name) songs in rotation.",
                    support: others.isEmpty ? nil : "Then \(others.joined(separator: ", ")).",
                    artwork: artists.prefix(3).compactMap(\.artworkURL),
                    symbol: Modality.music.systemImage
                )
            )
        }

        if let top = channels.first {
            prompts.append(
                Prompt(
                    viewer: "Someone who watches \(top.name)",
                    lead: top.subscribed
                        ? "Subscribed to \(top.name), and liked \(top.likes) of their videos."
                        : "\(top.likes) videos liked from \(top.name).",
                    support: channels.dropFirst().first.map { "Also \($0.name)." },
                    artwork: channels.prefix(3).compactMap(\.artworkURL),
                    symbol: Modality.media.systemImage
                )
            )
        }

        if let chronotype {
            let sport = sports.first
            prompts.append(
                Prompt(
                    viewer: sport.map { "Another \($0.name.lowercased()) person" } ?? "An \(chronotype.label.lowercased())",
                    lead: "\(chronotype.label). Moving by \(chronotype.wakeTime).",
                    support: sport.map { "\($0.name) \($0.sessions) times this year." },
                    artwork: [],
                    symbol: Modality.lifestyle.systemImage
                )
            )
        }

        return prompts
    }
}
