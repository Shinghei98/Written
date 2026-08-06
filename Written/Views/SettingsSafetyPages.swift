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
                    ForEach(words, id: \.self) { word in
                        HStack {
                            Text(word)
                                .font(.system(size: 16))
                                .foregroundStyle(GardenPalette.ink)
                            Spacer()
                            Button {
                                viewModel.unfilter(word: word)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(GardenPalette.muted)
                                    .frame(width: 32, height: 32)
                            }
                            .accessibilityLabel("Stop filtering \(word)")
                        }
                        .padding(.vertical, 6)
                    }
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
