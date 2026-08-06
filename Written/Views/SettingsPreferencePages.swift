import SwiftUI
import MapKit

/// The shared frame for a preference sub-page: back arrow left, title, Save
/// right.
///
/// **Save exists even though every page writes as it goes**, and that is a
/// deliberate redundancy. The binding is live, so leaving by the back arrow
/// keeps the change; the button is there because a page that offers a choice
/// and no way to commit it reads as broken, and because it gives the gesture
/// somewhere to land for anybody who does not trust a screen that saves itself.
private struct PreferencePage<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            GardenPalette.parchment.ignoresSafeArea()

            VStack(spacing: 0) {
                banner
                content()
                Spacer(minLength: 0)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var banner: some View {
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

            Button { dismiss() } label: {
                Text("Save")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(GardenPalette.gold)
                    .frame(height: 44)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
    }
}

// MARK: - Gender

struct GenderPreferenceView: View {
    @Binding var selection: DatingPreferences.Gender

    var body: some View {
        PreferencePage(title: "Gender preference") {
            VStack(spacing: 0) {
                ForEach(DatingPreferences.Gender.allCases) { option in
                    Button {
                        selection = option
                    } label: {
                        HStack {
                            Text(option.label)
                                .font(.system(size: 16))
                                .foregroundStyle(GardenPalette.ink)
                            Spacer()
                            // A ring that fills rather than a checkmark that
                            // appears: the unselected state has to be visible
                            // for the row to read as choosable at all.
                            ZStack {
                                Circle()
                                    .strokeBorder(
                                        selection == option
                                            ? GardenPalette.gold
                                            : GardenPalette.muted.opacity(0.4),
                                        lineWidth: 1.5
                                    )
                                    .frame(width: 22, height: 22)
                                if selection == option {
                                    Circle()
                                        .fill(GardenPalette.gold)
                                        .frame(width: 12, height: 12)
                                }
                            }
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    if option != DatingPreferences.Gender.allCases.last {
                        Rectangle()
                            .fill(GardenPalette.unreadBand)
                            .frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }
}

// MARK: - Matching radius

struct MatchingRadiusView: View {
    @Binding var miles: Int

    /// **Fetched when the page opens and never stored.**
    /// `LocationDistiller` exists precisely because this app looks up a
    /// placemark and drops the coordinate — "district and city, never a
    /// coordinate" is a rule `IdentitySummary` states outright. Drawing a map
    /// needs a centre, so it is asked for here, held in memory for as long as
    /// the page is open, and goes away with the view. Nothing writes it to
    /// disk, to `UserDefaults`, or to Postgres.
    @State private var region: MKCoordinateRegion?
    @State private var centre: CLLocationCoordinate2D?
    @State private var failed = false

    var body: some View {
        PreferencePage(title: "Matching radius") {
            VStack(spacing: 20) {
                map
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 20)

                SyncedSlider(
                    value: Binding(
                        get: { Double(miles) },
                        set: { miles = Int($0.rounded()) }
                    ),
                    range: Double(DatingPreferences.radiusFloor)...Double(DatingPreferences.radiusCeiling),
                    label: { "\(Int($0.rounded())) mile\(Int($0.rounded()) == 1 ? "" : "s")" }
                )
                .padding(.horizontal, 20)
            }
            .padding(.top, 8)
        }
        .task {
            // One fix, on appearing. A failure draws the slider without a map
            // rather than an error: the radius is still settable, and somebody
            // who declined location once should not be asked to care again here.
            guard centre == nil else { return }
            do {
                let coordinate = try await LocationDistiller().currentCoordinate()
                centre = coordinate
                region = MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: metres * 3,
                    longitudinalMeters: metres * 3
                )
            } catch {
                failed = true
            }
        }
        .onChange(of: miles) { _ in
            guard let centre else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                region = MKCoordinateRegion(
                    center: centre,
                    latitudinalMeters: metres * 3,
                    longitudinalMeters: metres * 3
                )
            }
        }
    }

    private var metres: CLLocationDistance { Double(miles) * 1609.34 }

    @ViewBuilder
    private var map: some View {
        if let region, centre != nil {
            RadiusMap(region: region, radiusMetres: metres)
        } else {
            ZStack {
                GardenPalette.card
                Text(failed ? "Location unavailable" : "Finding you…")
                    .font(.system(size: 14))
                    .foregroundStyle(GardenPalette.muted)
            }
        }
    }
}

/// `MKMapView` rather than SwiftUI's `Map`, because the grey disc is an
/// `MKCircle` overlay and SwiftUI's map had no overlay API on this project's
/// deployment target.
private struct RadiusMap: UIViewRepresentable {
    let region: MKCoordinateRegion
    let radiusMetres: CLLocationDistance

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.isZoomEnabled = false
        view.isScrollEnabled = false
        view.isRotateEnabled = false
        view.isPitchEnabled = false
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        view.setRegion(region, animated: true)
        view.removeOverlays(view.overlays)
        view.addOverlay(MKCircle(center: region.center, radius: radiusMetres))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.fillColor = UIColor(white: 0.35, alpha: 0.22)
            renderer.strokeColor = UIColor(white: 0.35, alpha: 0.45)
            renderer.lineWidth = 1
            return renderer
        }
    }
}

// MARK: - Age range

struct AgeRangeView: View {
    @Binding var minAge: Int
    @Binding var maxAge: Int

    var body: some View {
        PreferencePage(title: "Age range") {
            VStack(spacing: 28) {
                Text("\(minAge) – \(maxAge)")
                    .font(BrandFont.title(34))
                    .foregroundStyle(GardenPalette.ink)
                    .padding(.top, 24)

                RangeSlider(
                    low: Binding(get: { Double(minAge) }, set: { minAge = Int($0.rounded()) }),
                    high: Binding(get: { Double(maxAge) }, set: { maxAge = Int($0.rounded()) }),
                    range: Double(DatingPreferences.ageFloor)...Double(DatingPreferences.ageCeiling)
                )
                .padding(.horizontal, 20)
            }
        }
    }
}
