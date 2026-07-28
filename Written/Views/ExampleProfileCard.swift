import SwiftUI

/// The example match, rendered as an Instagram post.
///
/// The borrowed furniture — avatar, 4:5 photo, the row of icons, the caption
/// that opens with the handle in bold — is doing real work: it is the layout
/// every user already reads a stranger through, so the caption underneath is
/// read as *a person's words* rather than as output. Which is exactly the claim
/// the screen is making, since the words came out of their own library.
///
/// The palette stays the garden's, not Instagram's, so it sits on the page
/// rather than looking pasted onto it.
struct ExampleProfileCard: View {
    let profile: ExampleProfile

    /// Instagram's portrait post. The asset is 399×501, which is this ratio, so
    /// the photo fills the frame with nothing cropped away.
    /// Shared with `CropView`, so what someone frames is the shape it is shown
    /// at. Two copies of this number would eventually disagree.
    static let photoAspect: CGFloat = 4.0 / 5.0

    /// "27 · Clayton, St. Louis" — each part dropped when it is unknown, so a
    /// user with no Health age and no location fix still gets a clean line
    /// instead of stray separators.
    private var subtitle: String? {
        let parts = [profile.age.map(String.init), profile.place].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            photo
            actionRow
            caption
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(GardenPalette.ink.opacity(0.06), lineWidth: 1)
        }
    }

    // MARK: - Pieces

    private var headerRow: some View {
        HStack(spacing: 10) {
            ProfilePhoto(side: 34)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(GardenPalette.gold.opacity(0.35), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.handle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(GardenPalette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GardenPalette.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Edge to edge, the way a post is — the card's own padding stops at the
    /// photo and picks up again underneath it.
    private var photo: some View {
        Color.clear
            .aspectRatio(Self.photoAspect, contentMode: .fit)
            .overlay { ProfilePhoto(side: nil) }
            .clipped()
    }

    /// Decorative. None of these do anything, so they are hidden from
    /// VoiceOver and take no taps — an icon that looks live and isn't is worse
    /// than no icon.
    private var actionRow: some View {
        HStack(spacing: 16) {
            Image(systemName: "heart")
            Image(systemName: "bubble.right")
            Image(systemName: "paperplane")
            Spacer(minLength: 0)
            Image(systemName: "bookmark")
        }
        .font(.system(size: 19, weight: .regular))
        .foregroundStyle(GardenPalette.ink.opacity(0.75))
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(profile.captionLines.enumerated()), id: \.offset) { index, line in
                // The handle runs into the first line the way it does on a real
                // caption, so the block reads as one utterance rather than as
                // two labelled fields.
                if index == 0 {
                    (
                        Text(profile.handle).font(.system(size: 15, weight: .semibold))
                        + Text(" " + line).font(.system(size: 15))
                    )
                    .foregroundStyle(GardenPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Same ink as the first line: both are the same person
                    // talking, and a lighter grey read as a caption *about* the
                    // post rather than part of it.
                    Text(line)
                        .font(.system(size: 15))
                        .foregroundStyle(GardenPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }
}

/// The photo itself, loaded off the bundle.
///
/// `kris_wu.jpeg` is a loose resource under `Written/Resources/Assets/`, not an
/// asset-catalog imageset, so `Image("kris_wu")` finds nothing. This follows
/// the route the GIF logo and the Quicksand font already take — see
/// `AnimatedGIFView` and `BrandFont.register()`.
///
/// `side` is `nil` for the post, which fills whatever frame it is given, and a
/// number for the avatar.
private struct ProfilePhoto: View {
    let side: CGFloat?

    private static let image: UIImage? = {
        guard let url = Bundle.main.url(
            forResource: ExampleProfile.photoAsset,
            withExtension: ExampleProfile.photoExtension
        ) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }()

    var body: some View {
        Group {
            if let image = Self.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // The file is missing from the bundle — the swap in
                // `ExampleProfile.photoAsset` and the file on disk have gone out
                // of step. Say so quietly rather than collapsing to nothing.
                GardenPalette.gold.opacity(0.15)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .accessibilityLabel("Example profile photo")
    }
}
