import SwiftUI

/// Where the garden leads: what the distillation actually found.
///
/// Everything on this screen is read off the `DistilledRecord`s already on the
/// device — sources, counts, what kind of thing each record is, when it was
/// collected. The dating side of the product (dynamic prompts, matches) has no
/// data behind it yet, so it is named as pending rather than mocked up here.
struct DashboardView: View {
    @ObservedObject var viewModel: DistillViewModel
    var onBack: () -> Void = {}

    var body: some View {
        ZStack {
            GardenPalette.parchment.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    summary

                    if !viewModel.records.isEmpty {
                        Text("Sources")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(GardenPalette.muted)
                            .textCase(.uppercase)
                            .kerning(0.6)
                            .padding(.top, 4)

                        ForEach(viewModel.treeState.connectedModalities) { modality in
                            ForEach(viewModel.connectedSources(for: modality), id: \.self) { source in
                                sourceCard(source, in: modality)
                            }
                        }
                    }

                    nextUp
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.light)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Garden")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(GardenPalette.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the garden")

            Text("Your profile")
                .font(BrandFont.title(34))
                .foregroundStyle(GardenPalette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    /// The plant beside the two numbers that describe it: how much was
    /// distilled, and how much of the profile is grown.
    private var summary: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.records.count)")
                    .font(BrandFont.title(40))
                    .foregroundStyle(GardenPalette.ink)
                    .contentTransition(.numericText())

                Text(viewModel.records.count == 1 ? "item distilled" : "items distilled")
                    .font(.system(size: 15))
                    .foregroundStyle(GardenPalette.muted)

                Text("\(viewModel.treeState.connectedModalities.count) of \(Modality.allCases.count) branches grown")
                    .font(.system(size: 14))
                    .foregroundStyle(GardenPalette.gold)
                    .padding(.top, 8)

                if let last = lastCollected {
                    Text("Last distilled \(last.formatted(.dateTime.day().month(.abbreviated)))")
                        .font(.system(size: 13))
                        .foregroundStyle(GardenPalette.muted.opacity(0.8))
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            if let stage = viewModel.skeleton.illustrated {
                SeedlingView(stage: stage)
                    .frame(width: 108)
            }
        }
        .padding(18)
        .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(GardenPalette.ink.opacity(0.06), lineWidth: 1)
        }
    }

    /// One connected app: what it gave us, broken down by the kind of thing it
    /// was. The breakdown is the distillation's own `data_type`, so it stays
    /// honest as distillers are added rather than being a hand-kept list.
    private func sourceCard(_ source: String, in modality: Modality) -> some View {
        let records = viewModel.records.filter { $0.source == source }
        let kinds = breakdown(of: records)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppMark(source: source)

                VStack(alignment: .leading, spacing: 1) {
                    Text(Modality.displayName(forSource: source))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(GardenPalette.ink)
                    Text(modality.label)
                        .font(.system(size: 13))
                        .foregroundStyle(GardenPalette.muted)
                }

                Spacer(minLength: 0)

                Text("\(records.count)")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(GardenPalette.gold)
            }

            if !kinds.isEmpty {
                VStack(spacing: 6) {
                    ForEach(kinds, id: \.kind) { entry in
                        HStack(spacing: 8) {
                            Text(Self.label(for: entry.kind))
                                .font(.system(size: 14))
                                .foregroundStyle(GardenPalette.softInk)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Text("\(entry.count)")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(GardenPalette.muted)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(GardenPalette.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(GardenPalette.gold.opacity(0.18), lineWidth: 1)
        }
    }

    /// Named, not mocked: the ontology and embedding stages are what this data
    /// is *for*, and neither exists yet. A card of invented matches here would
    /// be the one thing on this screen that isn't true.
    private var nextUp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What happens next")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GardenPalette.ink)

            Text("Your distillation becomes keywords, then a place in the embedding space — that's what makes a prompt change depending on who's reading it.")
                .font(.system(size: 14))
                .foregroundStyle(GardenPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(GardenPalette.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 20))
        .padding(.top, 8)
    }

    // MARK: - Reading the records

    private var lastCollected: Date? {
        viewModel.records.map(\.collectedAt).max()
    }

    private func breakdown(of records: [DistilledRecord]) -> [(kind: String, count: Int)] {
        let grouped: [String: [DistilledRecord]] = Dictionary(grouping: records, by: \.dataType)
        var counted: [(kind: String, count: Int)] = grouped.map { (kind: $0.key, count: $0.value.count) }
        counted.sort { left, right in
            left.count == right.count ? left.kind < right.kind : left.count > right.count
        }
        return Array(counted.prefix(4))
    }

    /// `data_type` is snake_case in the CSV and stays that way in the records —
    /// this is display only, so nothing downstream sees a prettied name.
    private static func label(for kind: String) -> String {
        kind.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

#Preview {
    DashboardView(viewModel: DistillViewModel())
}
