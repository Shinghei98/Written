import CoreLocation
import MapKit
import SwiftUI

/// Which of the biographics rows is being corrected, if any.
enum BiographicsEditor: Identifiable {
    case name
    case birthday
    case gender
    case place
    case education
    case occupation

    var id: Self { self }
}

/// The card all three editors share: a scrim, a title, whatever the row needs,
/// and a Confirm.
///
/// Tapping the scrim cancels. Confirm is the only thing that writes — a sheet
/// that saved on dismissal would turn a stray tap into an edit.
struct BiographicsSheet<Content: View>: View {
    let title: String
    var subtitle: String?
    var confirmEnabled = true
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            GardenPalette.ink.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text(title)
                        .font(BrandFont.body(18))
                        .foregroundStyle(GardenPalette.ink)
                        .multilineTextAlignment(.center)

                    if let subtitle {
                        Text(subtitle)
                            .font(BrandFont.body(13))
                            .foregroundStyle(GardenPalette.muted)
                            .multilineTextAlignment(.center)
                    }
                }

                content

                Button(action: onConfirm) {
                    Text("Confirm")
                }
                .buttonStyle(
                    PressShrinkButtonStyle(
                        fill: GardenPalette.gold,
                        foreground: GardenPalette.card,
                        expands: false,
                        font: BrandFont.body(15),
                        horizontalPadding: 24,
                        minHeight: 42
                    )
                )
                .opacity(confirmEnabled ? 1 : 0.45)
                .disabled(!confirmEnabled)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(GardenPalette.ink.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: GardenPalette.ink.opacity(0.18), radius: 22, y: 10)
            .padding(.horizontal, 28)
        }
        .transition(.opacity)
    }
}

/// Correcting the name.
///
/// This closes something `CLAUDE.md` lists as a known gap: the name was captured
/// during onboarding and had no edit path afterwards, so a typo on the very
/// first screen was permanent. It is the same shape of bug the biographics rows
/// themselves had — a row that only rendered once it held a value, which nobody
/// could ever put a value into.
struct NameSheet: View {
    let current: String?
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        BiographicsSheet(
            title: "What should people call you?",
            subtitle: "This is the name on your profile.",
            confirmEnabled: !trimmed.isEmpty,
            onConfirm: { onSave(trimmed) },
            onCancel: onCancel
        ) {
            TextField("First name", text: $text)
                .font(BrandFont.body(17))
                .foregroundStyle(GardenPalette.ink)
                .multilineTextAlignment(.center)
                .textContentType(.givenName)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isFocused)
                .onSubmit { if !trimmed.isEmpty { onSave(trimmed) } }
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(GardenPalette.parchment, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(GardenPalette.ink.opacity(0.08), lineWidth: 1)
                }
        }
        .onAppear {
            text = current ?? ""
            isFocused = true
        }
    }
}

// MARK: - Education and occupation

/// The two free-text rows, which differ only in their words and their keyboard.
///
/// One view rather than two near-identical ones: they ask for a line of prose,
/// save it on Confirm, and nothing else. `NameSheet` stays separate because it
/// is a *name* — `.givenName` content type, autocorrect off, one line — and
/// folding it in here would mean three sets of exceptions rather than one view.
struct FreeTextSheet: View {
    let title: String
    let subtitle: String
    let placeholder: String
    let current: String?
    /// Schools run to several lines; a job title does not.
    var allowsMultipleLines = false
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        BiographicsSheet(
            title: title,
            subtitle: subtitle,
            confirmEnabled: !trimmed.isEmpty,
            onConfirm: { onSave(trimmed) },
            onCancel: onCancel
        ) {
            TextField(placeholder, text: $text, axis: allowsMultipleLines ? .vertical : .horizontal)
                .font(BrandFont.body(17))
                .foregroundStyle(GardenPalette.ink)
                .multilineTextAlignment(.center)
                .lineLimit(allowsMultipleLines ? 1...4 : 1...1)
                // Capitalised by words: these are proper nouns more often than
                // not — "Reed College", "Product Designer".
                .textInputAutocapitalization(.words)
                // `.return` rather than `.done` when several lines are wanted, so
                // the keyboard offers a way to start the next school instead of
                // dismissing on the first one.
                .submitLabel(allowsMultipleLines ? .return : .done)
                .focused($isFocused)
                .onSubmit { if !allowsMultipleLines && !trimmed.isEmpty { onSave(trimmed) } }
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(GardenPalette.parchment, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(GardenPalette.ink.opacity(0.08), lineWidth: 1)
                }
        }
        .onAppear {
            text = current ?? ""
            isFocused = true
        }
    }
}

// MARK: - Birthday

struct BirthdaySheet: View {
    let onSave: (Int, Int, Int) -> Bool
    let onCancel: () -> Void

    @State private var month = ""
    @State private var day = ""
    @State private var year = ""
    /// Set by a failed Confirm, not by opening: three red boxes for not having
    /// typed yet is scolding someone for nothing. It clears as soon as the
    /// entry becomes valid.
    @State private var rejected = false

    /// Which box the keyboard is in, so a full one can hand over to the next.
    private enum Field { case month, day, year }
    @FocusState private var focused: Field?

    private static let errorRed = Color(red: 0.72, green: 0.20, blue: 0.16)

    /// `nil` for empty or impossible — 31 February included, which
    /// `DateComponents` builds happily unless asked to validate.
    private var entered: DateComponents? {
        guard let month = Int(month), let day = Int(day), let year = Int(year) else { return nil }
        var components = DateComponents()
        components.month = month
        components.day = day
        components.year = year
        return components.isValidDate(in: Calendar.current) ? components : nil
    }

    private var showsError: Bool { rejected && entered == nil }

    var body: some View {
        BiographicsSheet(
            title: "When's your birthday?",
            onConfirm: confirm,
            onCancel: onCancel
        ) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    field("Month", text: $month, width: 74, field: .month, digits: 2)
                    field("Day", text: $day, width: 62, field: .day, digits: 2)
                    field("Year", text: $year, width: 82, field: .year, digits: 4)
                }

                if showsError {
                    Text("Enter a valid date of birth")
                        .font(BrandFont.body(13))
                        .foregroundStyle(Self.errorRed)
                }
            }
        }
    }

    private func confirm() {
        guard let entered, let month = entered.month, let day = entered.day, let year = entered.year,
              onSave(month, day, year) else {
            withAnimation(.easeOut(duration: 0.15)) { rejected = true }
            return
        }
    }

    private func field(
        _ placeholder: String,
        text: Binding<String>,
        width: CGFloat,
        field: Field,
        digits: Int
    ) -> some View {
        TextField("", text: text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(BrandFont.body(17))
            .foregroundStyle(GardenPalette.ink)
            .focused($focused, equals: field)
            // Typing "12" in Month should land you in Day, the way every date
            // entry on a phone behaves. Digits are filtered here too, because a
            // number pad still admits paste — and a box capped at its own width
            // can't silently swallow a fourth digit of a year.
            .onChange(of: text.wrappedValue) { value in
                let cleaned = String(value.filter(\.isNumber).prefix(digits))
                if cleaned != value { text.wrappedValue = cleaned }
                guard cleaned.count == digits else { return }
                switch field {
                case .month: focused = .day
                case .day: focused = .year
                // Nothing after the year, so the keyboard goes rather than
                // sitting over the Confirm the user is now reaching for.
                case .year: focused = nil
                }
            }
            // Drawn rather than passed to `TextField`: the system placeholder is
            // a grey the parchment fights, and this keeps it in the palette and
            // in the same face as everything else here.
            .overlay {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(BrandFont.body(17))
                        .foregroundStyle(GardenPalette.muted.opacity(0.55))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: 44)
            .background(GardenPalette.parchment, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        showsError ? Self.errorRed : GardenPalette.ink.opacity(0.10),
                        lineWidth: showsError ? 1.5 : 1
                    )
            }
    }
}

// MARK: - Gender

struct GenderSheet: View {
    let current: String?
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var selection: String?

    /// Male and female first because they are what most people pick, then the
    /// rest — not as an "other" bucket, which is a way of saying *not one of
    /// the real ones*, but as named options of equal standing.
    static let options = [
        "Male", "Female",
        "Non-binary", "Genderqueer", "Genderfluid", "Agender", "Bigender",
        "Transgender man", "Transgender woman", "Two-spirit", "Intersex",
        "Prefer not to say"
    ]

    var body: some View {
        BiographicsSheet(
            title: "Which gender best describes you?",
            confirmEnabled: selection != nil,
            onConfirm: { if let selection { onSave(selection) } },
            onCancel: onCancel
        ) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Self.options, id: \.self) { option in
                        Button {
                            selection = option
                        } label: {
                            HStack(spacing: 10) {
                                Text(option)
                                    .font(BrandFont.body(16))
                                    .foregroundStyle(GardenPalette.ink)

                                Spacer(minLength: 8)

                                if selection == option {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(GardenPalette.gold)
                                }
                            }
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if option != Self.options.last {
                            Divider().overlay(GardenPalette.ink.opacity(0.06))
                        }
                    }
                }
            }
            // Tall enough to show the list is longer than male and female, short
            // enough to leave the Confirm on screen with a keyboard-free sheet.
            .frame(maxHeight: 260)
            .onAppear { selection = current }
        }
    }
}

// MARK: - Place

struct PlaceSheet: View {
    let initialCoordinate: CLLocationCoordinate2D?
    let onLocate: () async -> CLLocationCoordinate2D?
    let onSave: (CLLocationCoordinate2D) -> Void
    let onCancel: () -> Void

    @State private var region: MKCoordinateRegion
    @State private var query = ""
    @State private var isLocating = false
    /// The in-flight typed-text lookup, held so the next keystroke can cancel
    /// it. Without this the map lands on whichever of several overlapping
    /// searches happens to finish last, which is rarely the newest one.
    @State private var searchTask: Task<Void, Never>?

    init(
        initialCoordinate: CLLocationCoordinate2D?,
        onLocate: @escaping () async -> CLLocationCoordinate2D?,
        onSave: @escaping (CLLocationCoordinate2D) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialCoordinate = initialCoordinate
        self.onLocate = onLocate
        self.onSave = onSave
        self.onCancel = onCancel
        // Somewhere rather than nowhere: an unset map opens on the middle of the
        // Atlantic, which reads as broken.
        let centre = initialCoordinate ?? CLLocationCoordinate2D(latitude: 38.63, longitude: -90.20)
        _region = State(initialValue: MKCoordinateRegion(
            center: centre,
            span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
        ))
    }

    var body: some View {
        BiographicsSheet(
            title: "Where would you like to date?",
            subtitle: "It is temporary. You can change anytime.",
            onConfirm: { onSave(region.center) },
            onCancel: onCancel
        ) {
            VStack(spacing: 12) {
                ZStack {
                    Map(coordinateRegion: $region)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    // The pin stays dead centre and the map moves under it, so
                    // "where the pin is" and "where the map is centred" can
                    // never disagree — which is what Confirm reads.
                    Image(systemName: "mappin")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(GardenPalette.ink)
                        .shadow(color: .white.opacity(0.8), radius: 2)
                        .offset(y: -10)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    Button {
                        Task {
                            isLocating = true
                            defer { isLocating = false }
                            guard let coordinate = await onLocate() else { return }
                            withAnimation { region.center = coordinate }
                        }
                    } label: {
                        Image(systemName: isLocating ? "ellipsis" : "location.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(GardenPalette.ink.opacity(0.85), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .accessibilityLabel("Use my location")
                }

                TextField("", text: $query)
                    .font(BrandFont.body(15))
                    .foregroundStyle(GardenPalette.ink)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit { search(after: 0) }
                    .onChange(of: query) { _ in search(after: 0.45) }
                    .overlay(alignment: .leading) {
                        if query.isEmpty {
                            Text("Enter your address, neighborhood, or ZIP")
                                .font(BrandFont.body(15))
                                .foregroundStyle(GardenPalette.muted.opacity(0.55))
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(GardenPalette.ink.opacity(0.15))
                            .frame(height: 1)
                    }
            }
        }
    }

    /// Moves the map to whatever the typed text names, as it is typed. The pin
    /// is still what gets saved, so a rough match can be nudged rather than
    /// being wrong.
    ///
    /// `delay` is what keeps this from firing a lookup per keystroke: typing
    /// restarts the timer, and only the pause at the end of a word actually
    /// reaches MapKit. Submitting passes 0 — the user has already stopped.
    private func search(after delay: TimeInterval) {
        searchTask?.cancel()

        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return }

        searchTask = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }

            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            // Biases results toward what's on screen, so "Springfield" resolves
            // to the near one rather than the most famous one.
            request.region = region

            guard let response = try? await MKLocalSearch(request: request).start(),
                  let match = response.mapItems.first, !Task.isCancelled else { return }

            withAnimation {
                region = MKCoordinateRegion(
                    center: match.placemark.coordinate,
                    span: span(for: match.placemark)
                )
            }
        }
    }

    /// Zoom that matches how big the thing named is: a ZIP or a street address
    /// should land close in, a city shouldn't. MapKit hands back a radius for
    /// most matches; when it doesn't, the map keeps the zoom it had rather than
    /// jumping to an arbitrary one.
    private func span(for placemark: MKPlacemark) -> MKCoordinateSpan {
        guard let circle = placemark.region as? CLCircularRegion else { return region.span }
        // Radius to degrees of latitude, doubled to frame the whole circle, then
        // held between a street and a small country.
        let degrees = min(max((circle.radius * 2) / 111_000, 0.01), 3)
        return MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)
    }
}
