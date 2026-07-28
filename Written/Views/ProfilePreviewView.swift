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

    var body: some View {
        ZStack(alignment: .top) {
            GardenPalette.parchment.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    ExampleProfileCard(profile: viewModel.exampleProfile)
                }
                .padding(.horizontal, 20)
                .padding(.top, 96)
                .padding(.bottom, 36)
            }

            topBar
        }
        .preferredColorScheme(.light)
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
