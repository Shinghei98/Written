import SwiftUI
import Contacts

/// People this user does not want seeing them.
///
/// Built on `BanList.Kind.person`, which has existed since blocking was added
/// to the chat — so a block made here and a block made from a profile are the
/// same fact, cached locally, pushed by `SyncService.pushBans`, and restored on
/// a new device. Nothing new is stored.
struct BlockListView: View {
    @ObservedObject var viewModel: DistillViewModel

    @State private var isSyncingContacts = false
    @State private var contactsDenied = false
    @State private var isAdding = false
    @State private var draft = ""

    var body: some View {
        SettingsSubPage(title: "Block list") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sync contacts")
                            .font(.system(size: 16))
                            .foregroundStyle(GardenPalette.ink)
                        Text(contactsDenied
                             ? "Written cannot read your contacts. Turn it on in Settings to block people you already know."
                             : "Blocks everyone in your phone's contacts, so people you already know cannot see you.")
                            .font(.system(size: 13))
                            .foregroundStyle(GardenPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $isSyncingContacts)
                        .labelsHidden()
                        .tint(GardenPalette.gold)
                }
                .padding(.vertical, 12)

                Rectangle().fill(GardenPalette.unreadBand).frame(height: 1)

                entries

                Button {
                    isAdding = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Block someone")
                            .font(.system(size: 16))
                    }
                    .foregroundStyle(GardenPalette.gold)
                    .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 20)
        }
        // **Asked on the toggle, never on appear.** This project lost a week to
        // two permission prompts colliding, and the rule that came out of it is
        // that nothing in this app raises a system alert from `onAppear` or
        // `task`. A contacts prompt fires because somebody reached for it.
        .onChange(of: isSyncingContacts) { on in
            guard on else { return }
            Task { await importContacts() }
        }
        .alert("Block someone", isPresented: $isAdding) {
            TextField("Name or phone number", text: $draft)
            Button("Cancel", role: .cancel) { draft = "" }
            Button("Block") {
                viewModel.block(name: draft)
                draft = ""
            }
        }
    }

    @ViewBuilder
    private var entries: some View {
        let blocked = viewModel.blockedKeys.sorted()
        if blocked.isEmpty {
            Text("Nobody is blocked.")
                .font(.system(size: 14))
                .foregroundStyle(GardenPalette.muted)
                .padding(.vertical, 16)
        } else {
            ForEach(blocked, id: \.self) { key in
                HStack {
                    Text(key)
                        .font(.system(size: 16))
                        .foregroundStyle(GardenPalette.ink)
                    Spacer()
                    Button {
                        viewModel.unblock(key: key)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(GardenPalette.muted)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Unblock \(key)")
                }
                .padding(.vertical, 6)
            }
        }
    }

    /// Names only. **No phone numbers or emails leave the device** — the ban
    /// list travels to Postgres, and uploading somebody's address book would be
    /// collecting data about people who never agreed to anything. A name is
    /// what the block matches on here.
    private func importContacts() async {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else {
            contactsDenied = true
            isSyncingContacts = false
            return
        }

        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var names: [String] = []
        try? store.enumerateContacts(with: request) { contact, _ in
            let name = "\(contact.givenName) \(contact.familyName)"
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.append(name) }
        }
        viewModel.block(names: names)
    }
}

/// Words that keep an invitation from ever being shown.
///
/// `0018` let a like carry a note, and this is the filter on it. Matching
/// happens on read rather than at the server: the note is already down the wire
/// by the time anybody could filter it, and a client-side test needs no policy
/// change and no migration.
struct WordFilterView: View {
    @ObservedObject var viewModel: DistillViewModel

    @State private var isAdding = false
    @State private var draft = ""

    var body: some View {
        SettingsSubPage(title: "Word filter") {
            VStack(alignment: .leading, spacing: 0) {
                let words = viewModel.filteredWords.sorted()

                if words.isEmpty {
                    Text("No words are filtered. Invitations arrive as they were written.")
                        .font(.system(size: 14))
                        .foregroundStyle(GardenPalette.muted)
                        .padding(.vertical, 16)
                } else {
                    // **Tags rather than rows, because a filtered word is not a
                    // setting with a value.** A full-width row per word implies
                    // each has properties worth the space; a list of short
                    // strings reads faster packed, and twenty of them fit on one
                    // screen instead of five.
                    FlowLayout(spacing: 8) {
                        ForEach(words, id: \.self) { word in
                            WordTag(word: word) { viewModel.unfilter(word: word) }
                        }
                    }
                    .padding(.vertical, 12)
                }

                Button {
                    isAdding = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Add a word")
                            .font(.system(size: 16))
                    }
                    .foregroundStyle(GardenPalette.gold)
                    .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 20)
        }
        .alert("Add a word", isPresented: $isAdding) {
            TextField("Word", text: $draft)
            Button("Cancel", role: .cancel) { draft = "" }
            Button("Add") {
                viewModel.filter(word: draft)
                draft = ""
            }
        } message: {
            Text("Invitations whose message contains this word will not be shown to you.")
        }
    }
}

/// One filtered word, with the cross that removes it.
///
/// **Only the cross removes it, not the whole tag.** A pill that deletes itself
/// wherever you touch it is a word lost to a thumb resting on the screen, and
/// there is no undo here — the word simply stops being filtered and the next
/// invitation carrying it arrives.
private struct WordTag: View {
    let word: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(word)
                .font(.system(size: 15))
                .foregroundStyle(GardenPalette.ink)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(GardenPalette.muted.opacity(0.55))
            }
            .accessibilityLabel("Stop filtering \(word)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Capsule().fill(GardenPalette.unreadBand))
    }
}

/// Lays its subviews left to right, wrapping to the next line when the row is
/// full.
///
/// **A real `Layout` rather than an approximation**, which iOS 16 is the floor
/// for and this project's deployment target is exactly. The usual workarounds —
/// a `LazyVGrid` with adaptive columns, or measuring text and building rows by
/// hand — both get variable-width items wrong: the grid forces every cell to
/// one width, so "sex" and "cryptocurrency" would occupy the same box, and hand
/// measurement has to guess at font metrics the layout system already knows.
///
/// Sized against `proposal.replacingUnspecifiedDimensions().width`, so it wraps
/// to the width it is actually given rather than to the screen — which matters
/// because this sits inside a page with its own horizontal padding.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.replacingUnspecifiedDimensions().width)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height } +
            spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.replacingUnspecifiedDimensions().width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    /// Walked once and reused by both passes, so the wrap points cannot differ
    /// between measuring and placing — which is how a flow layout ends up
    /// reporting one height and drawing another.
    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            // The first item on a row is placed however wide it is: wrapping it
            // would leave an empty line above an item that still overflows.
            if !current.indices.isEmpty, x + size.width > width {
                rows.append(current)
                current = Row()
                x = 0
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// The same banner as the preference pages, without a Save button — these
/// pages have no draft to commit. Every edit is applied as it is made, because
/// a block that needed confirming is a block somebody thinks they made.
struct SettingsSubPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            GardenPalette.parchment.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(GardenPalette.muted)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back")

                    Spacer()

                    Text(title)
                        .font(BrandFont.title(20))
                        .foregroundStyle(GardenPalette.ink)

                    Spacer()

                    // Balances the back arrow so the title sits centred.
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 12)
                .frame(height: 56)

                ScrollView { content() }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
