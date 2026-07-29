import SwiftUI

/// What the distillation is *for*: someone the user could meet, written out of
/// the user's own records.
///
/// Reached by confirming the dashboard — they have just checked and edited what
/// was collected, so this is the payoff for that work. One profile, and nothing
/// beside it: the page makes a single claim, and every extra card was another
/// way of restating it.
///
/// `DynamicPrompts` still exists and is still what the per-reader rewriting will
/// be built from; it is simply not what this screen shows any more.
struct ProfilePreviewView: View {
    @ObservedObject var viewModel: DistillViewModel
    var onBack: () -> Void = {}

    /// The end of onboarding. Everything before this was about building the
    /// profile; this is the first move outward, into other people.
    var onExplore: () -> Void = {}

    var body: some View {
        ZStack(alignment: .top) {
            GardenPalette.parchment.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    ExampleProfileCard(profile: viewModel.exampleProfile)

                    explore
                }
                .padding(.horizontal, 20)
                .padding(.top, 96)
                .padding(.bottom, 36)
            }

            topBar
        }
        .preferredColorScheme(.light)
    }

    /// Full width and at the foot of the page, unlike the Dashboard link in the
    /// bar above: this is the one thing to do here, and everything above it is
    /// the argument for doing it.
    private var explore: some View {
        Button(action: onExplore) {
            HStack(spacing: 7) {
                Image(systemName: "book")
                    .font(.system(size: 15, weight: .semibold))
                Text("Explore")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(GardenPalette.parchment)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(GardenPalette.gold, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
        .accessibilityHint("See the people you could meet")
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Dashboard")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(GardenPalette.muted)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the dashboard")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .background(GardenPalette.parchment)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People you will see")
                .font(BrandFont.title(38))
                .foregroundStyle(GardenPalette.ink)

            Text("Meet someone who understands your world")
                .font(.system(size: 15))
                .foregroundStyle(GardenPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }
}

#Preview {
    ProfilePreviewView(viewModel: DistillViewModel())
}
