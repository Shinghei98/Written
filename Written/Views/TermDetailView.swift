import SwiftUI

/// What is actually behind one term on the Memories page.
///
/// **The page could not be argued with before this existed.** A term drew as
/// its own text and nothing else — no source, no `data_type`, no sight of the
/// rows underneath — so the only judgement available was "do I recognise this
/// word", which is not the same question as "is this right about me". A test
/// user asked to correct their own distillation needs the evidence in front of
/// them, and the two verbs this app already has — strike it off, type your own
/// — only become usable once they can see what they are answering.
///
/// The case that forced it: Spotify returns no composer and no track genre, so
/// a Bach recording files under whoever performed it. The chip says "Itzhak
/// Perlman", which is a real artist the person really listens to — there is
/// nothing on the card to suggest anything is wrong. Reading the rows, with the
/// album beside the `subject` that decided the term, is what turns that from
/// invisible into a one-tap fix. Apple Music is only partly better: on one real
/// library 42 of 481 classical rows carried a composer at all.
///
/// **Read-only, and deliberately.** There is no rename here and no undo. The
/// correction model is unchanged — strike the wrong term off, add the right one
/// — and this exists to make that model informed rather than to replace it.
struct TermDetailView: View {

    @ObservedObject var viewModel: DistillViewModel
    let term: Ontology.Term
    let domain: Ontology.Domain
    var onClose: () -> Void = {}

    /// The rows this term stands for.
    ///
    /// **`DistilledRecord.matches(kind:keys:)` — the same predicate
    /// `applyingBans` uses, which is the whole reason it was lifted out of the
    /// view model.** What somebody reads here has to be exactly what "Strike it
    /// off" would take. A second matching rule written for this screen would
    /// drift from the one that governs the button, and nothing on the page
    /// would say so until the wrong songs disappeared.
    private var rows: [DistilledRecord] {
        let keys = Set(term.banValues.map { $0.lowercased() })
        return viewModel.records.filter { $0.matches(kind: term.kind, keys: keys) }
    }

    /// Grouped the way the glyphs on the card are: by source, in the same order.
    private var grouped: [(source: String, rows: [DistilledRecord])] {
        Dictionary(grouping: rows, by: \.source)
            .map { (source: $0.key, rows: $0.value) }
            .sorted { $0.source < $1.source }
    }

    var body: some View {
        ZStack(alignment: .top) {
            GardenPalette.parchment.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heading
                    if rows.isEmpty { nothingBehindIt } else { evidence }
                    verbs
                }
                .padding(.horizontal, 20)
                .padding(.top, 64)
                .padding(.bottom, 40)
            }

            header
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Text(domain.label)
                .font(BrandFont.title(22))
                .foregroundStyle(GardenPalette.ink)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(GardenPalette.parchment.opacity(0.96))
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ArtworkTile(name: term.text, url: term.artworkURL, side: 52, corner: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(term.text)
                        .font(BrandFont.title(24))
                        .foregroundStyle(GardenPalette.ink)
                    // The unit `Term.weight` documents, spelled rather than
                    // drawn — the card gives it as a bar and a bar says only
                    // "less than that one".
                    Text(countPhrase)
                        .font(.system(size: 13))
                        .foregroundStyle(GardenPalette.muted)
                }
            }
            // In full here, where there is room. The card has the glyphs.
            Text(term.sources.sorted().map(Modality.displayName(forSource:)).joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(GardenPalette.muted)
                .padding(.top, 2)
        }
    }

    /// "37 songs", "9 episodes", "4 sessions" — the thing the source counts in.
    private var countPhrase: String {
        let noun: String
        switch term.kind {
        case .artist:  noun = term.weight == 1 ? "song" : "songs"
        case .show:    noun = term.weight == 1 ? "episode" : "episodes"
        case .sport:   noun = term.weight == 1 ? "session" : "sessions"
        case .event:   noun = term.weight == 1 ? "entry" : "entries"
        case .channel: noun = term.weight == 1 ? "video" : "videos"
        case .person, .word: noun = "rows"
        }
        return "\(term.weight) \(noun)"
    }

    // MARK: - The evidence

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WHERE THIS CAME FROM")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(GardenPalette.muted)

            ForEach(grouped, id: \.source) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(Modality.displayName(forSource: group.source))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(GardenPalette.softInk)
                        .padding(.bottom, 8)

                    ForEach(Array(group.rows.enumerated()), id: \.offset) { index, record in
                        if index > 0 {
                            Divider().overlay(GardenPalette.ink.opacity(0.06))
                        }
                        row(record)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(GardenPalette.card)
                )
            }
        }
    }

    private func row(_ record: DistilledRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.name.isEmpty ? "—" : record.name)
                    .font(.system(size: 14))
                    .foregroundStyle(GardenPalette.ink)
                Spacer(minLength: 6)
                // The shape of the row, which is what tells a `top_track` from
                // a `recently_played` — two very different claims that draw
                // identically on the card.
                Text(record.dataType)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(GardenPalette.muted.opacity(0.8))
            }
            if !record.creator.isEmpty {
                Text(record.creator)
                    .font(.system(size: 12))
                    .foregroundStyle(GardenPalette.muted)
            }
            ForEach(shownExtras(of: record), id: \.0) { key, value in
                Text("\(key): \(value)")
                    .font(.system(size: 11))
                    .foregroundStyle(GardenPalette.muted.opacity(0.85))
                    .lineLimit(2)
            }
            if record.isRemovedByUser {
                Text("struck off")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GardenPalette.gold)
            }
        }
        .padding(.vertical, 7)
    }

    /// The `extra` keys worth reading, in a fixed order.
    ///
    /// **An allowlist rather than a dump**, because `extra` carries 200-character
    /// artwork URLs and a wall of `topics=`/`tags=` that answers no question
    /// anybody is asking here. These are the keys that let somebody judge
    /// "should this have said Bach?".
    ///
    /// **`subject` first and always** — it is the field that *decided* the term,
    /// so it is the one thing that explains the row above it. On a Spotify row
    /// its value being the performer, next to a plainly classical album, is the
    /// whole explanation for a wrong answer; before this screen that reasoning
    /// was not available anywhere in the app.
    private func shownExtras(of record: DistilledRecord) -> [(String, String)] {
        let keys: [String]
        switch term.kind {
        case .artist:
            keys = ["subject", "composer", "album", "genres", "released",
                    "play_count", "last_played"]
        case .event:
            keys = ["organizer", "calendar", "booked", "start"]
        case .show:
            keys = ["subject", "progress"]
        case .sport:
            keys = ["sessions", "minutes", "duration_min"]
        case .channel:
            keys = ["topics", "category_id"]
        case .person, .word:
            keys = []
        }
        return keys.compactMap { key in
            guard let value = record.extraValue(key), !value.isEmpty else { return nil }
            return (key, value)
        }
    }

    /// A term with no rows behind it. Rare and worth saying out loud rather than
    /// drawing an empty card: it means the rows were struck off, or arrived from
    /// a source that has since been disconnected.
    private var nothingBehindIt: some View {
        Text("Nothing is behind this any more — the rows it came from were struck off or the source was disconnected.")
            .font(.system(size: 13))
            .foregroundStyle(GardenPalette.muted)
            .padding(.vertical, 8)
    }

    // MARK: - The two verbs that already exist

    private var verbs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(GardenPalette.ink.opacity(0.08))

            Button {
                viewModel.banTerm(term)
                onClose()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle")
                    Text("Strike it off")
                }
                .font(.system(size: 15))
                .foregroundStyle(GardenPalette.ink)
            }
            .buttonStyle(.plain)

            // Deliberately a sentence rather than a second button. Adding a term
            // is not the opposite of striking one off, and putting the two side
            // by side would read as "replace", which is a verb this app does not
            // have — the card's own "What did we miss?" is where an addition
            // belongs, and it writes a separate row rather than editing this one.
            Text("Wrong? Strike it off, then add what it should have said on the \(domain.label) card.")
                .font(.system(size: 12))
                .foregroundStyle(GardenPalette.muted)
        }
    }
}
