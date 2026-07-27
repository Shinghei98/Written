import SwiftUI

/// Full-screen country list, presented from the bottom by the dial-code button.
///
/// The four featured countries sit above a grey band, then every remaining
/// country in the user's collation order.
struct CountryPickerView: View {
    @Binding var selection: Country
    var onClose: () -> Void = {}

    var body: some View {
        ZStack {
            SignInPalette.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Country.featured) { country in
                            row(for: country)
                        }

                        Rectangle()
                            .fill(SignInPalette.field)
                            .frame(height: 20)

                        ForEach(Country.alphabetical) { country in
                            row(for: country)
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Select country")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SignInPalette.ink)

                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(SignInPalette.ink)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 8)
            }
            .padding(.vertical, 6)

            Divider()
        }
    }

    private func row(for country: Country) -> some View {
        VStack(spacing: 0) {
            Button {
                selection = country
                onClose()
            } label: {
                HStack(spacing: 12) {
                    Text(country.name)
                        .font(.system(size: 17))
                        .foregroundStyle(SignInPalette.ink)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 12)

                    Text(country.flag)
                        .font(.system(size: 20))
                    Text(country.dialCode)
                        .font(.system(size: 17))
                        .foregroundStyle(SignInPalette.ink)
                }
                .padding(.horizontal, 20)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.leading, 20)
        }
    }
}

#Preview {
    CountryPickerView(selection: .constant(.unitedStates))
}
