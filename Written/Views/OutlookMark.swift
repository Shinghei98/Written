import SwiftUI

/// Microsoft Outlook's 2025 mark, transcribed from the official SVG.
///
/// **Hand-drawn three times and wrong three times, so it is no longer
/// hand-drawn.** The attempts were: the pre-2025 icon; a rectangle with a
/// diagonal band; and a pentagon pointing the wrong way with two invented
/// triangles. Each was reasoned from a low-resolution render, and each got the
/// palette closer while the geometry stayed wrong — which is the tell that the
/// method was the problem rather than the effort.
///
/// These coordinates come from the SVG's own `d` attributes, converted from its
/// `viewBox` (60 90.4 570.02 539.67) into the unit square by a script. The
/// envelope peaks at the **top** — apex near (0.53, 0.00) — with the V where
/// the two wings meet at the **bottom** centre, which is the opposite of what
/// the last version drew. Nothing here was chosen by eye.
///
/// Gradient stops are the SVG's own, likewise. Duplicate paths in the source —
/// the shadow overlays, drawn twice with different gradients — are collapsed to
/// one, because at 48pt they are a wash rather than a shadow.
enum OutlookMark {

    static func pt(_ r: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
    }

    // shape 0  fill=url(#linear0)
    static func shape0(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: pt(r, 0.7087, 0.0922))
        p.addLine(to: pt(r, 0.1046, 0.4966))
        p.addLine(to: pt(r, 0.0527, 0.4101))
        p.addLine(to: pt(r, 0.0527, 0.3355))
        p.addCurve(to: pt(r, 0.0873, 0.2682), control1: pt(r, 0.0527, 0.3083), control2: pt(r, 0.0657, 0.2830))
        p.addLine(to: pt(r, 0.4384, 0.0275))
        p.addCurve(to: pt(r, 0.6143, 0.0275), control1: pt(r, 0.4919, -0.0091), control2: pt(r, 0.5608, -0.0091))
        p.closeSubpath()
        p.move(to: pt(r, 0.7087, 0.0922))
        return p
    }
    // shape 1  fill=url(#linear1)
    static func shape1(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: pt(r, 0.6089, 0.0240))
        p.addCurve(to: pt(r, 0.6143, 0.0275), control1: pt(r, 0.6107, 0.0251), control2: pt(r, 0.6125, 0.0263))
        p.addLine(to: pt(r, 0.8884, 0.2153))
        p.addLine(to: pt(r, 0.2089, 0.6702))
        p.addLine(to: pt(r, 0.1046, 0.4965))
        p.addLine(to: pt(r, 0.6033, 0.1620))
        p.addCurve(to: pt(r, 0.6089, 0.0240), control1: pt(r, 0.6505, 0.1303), control2: pt(r, 0.6526, 0.0590))
        p.closeSubpath()
        p.move(to: pt(r, 0.6089, 0.0240))
        return p
    }
    // shape 2  fill=url(#linear3)
    static func shape2(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: pt(r, 0.4800, 0.7571))
        p.addLine(to: pt(r, 0.2089, 0.6702))
        p.addLine(to: pt(r, 0.7853, 0.2843))
        p.addCurve(to: pt(r, 0.7851, 0.1446), control1: pt(r, 0.8338, 0.2518), control2: pt(r, 0.8337, 0.1770))
        p.addLine(to: pt(r, 0.7825, 0.1429))
        p.addLine(to: pt(r, 0.7899, 0.1478))
        p.addLine(to: pt(r, 0.9654, 0.2680))
        p.addCurve(to: pt(r, 1.0000, 0.3353), control1: pt(r, 0.9869, 0.2828), control2: pt(r, 1.0000, 0.3081))
        p.addLine(to: pt(r, 1.0000, 0.4075))
        p.closeSubpath()
        p.move(to: pt(r, 0.4800, 0.7571))
        return p
    }
    // shape 3  fill=url(#radial0)
    static func shape3(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: pt(r, 0.6143, 0.0275))
        p.addCurve(to: pt(r, 0.4384, 0.0275), control1: pt(r, 0.5608, -0.0091), control2: pt(r, 0.4919, -0.0091))
        p.addLine(to: pt(r, 0.0873, 0.2682))
        p.addCurve(to: pt(r, 0.0527, 0.3355), control1: pt(r, 0.0657, 0.2830), control2: pt(r, 0.0527, 0.3083))
        p.addLine(to: pt(r, 0.0527, 0.3391))
        p.addCurve(to: pt(r, 0.0890, 0.4061), control1: pt(r, 0.0535, 0.3664), control2: pt(r, 0.0671, 0.3915))
        p.addLine(to: pt(r, 0.5257, 0.6969))
        p.addLine(to: pt(r, 0.9634, 0.4066))
        p.addCurve(to: pt(r, 0.9999, 0.3368), control1: pt(r, 0.9861, 0.3915), control2: pt(r, 0.9999, 0.3651))
        p.addLine(to: pt(r, 0.9999, 0.4075))
        p.addLine(to: pt(r, 1.0000, 0.3353))
        p.addCurve(to: pt(r, 0.9654, 0.2680), control1: pt(r, 1.0000, 0.3081), control2: pt(r, 0.9869, 0.2828))
        p.closeSubpath()
        p.move(to: pt(r, 0.6143, 0.0275))
        return p
    }
    // shape 4  fill=url(#linear5)
    static func shape4(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: pt(r, 0.4487, 1.0000))
        p.addLine(to: pt(r, 0.8354, 1.0000))
        p.addCurve(to: pt(r, 0.9999, 0.8262), control1: pt(r, 0.9263, 1.0000), control2: pt(r, 0.9999, 0.9222))
        p.addLine(to: pt(r, 0.9999, 0.3368))
        p.addCurve(to: pt(r, 0.9634, 0.4066), control1: pt(r, 0.9999, 0.3651), control2: pt(r, 0.9861, 0.3915))
        p.addLine(to: pt(r, 0.3881, 0.7881))
        p.addCurve(to: pt(r, 0.3383, 0.8833), control1: pt(r, 0.3571, 0.8087), control2: pt(r, 0.3383, 0.8446))
        p.addCurve(to: pt(r, 0.4487, 1.0000), control1: pt(r, 0.3383, 0.9477), control2: pt(r, 0.3877, 1.0000))
        p.closeSubpath()
        p.move(to: pt(r, 0.4487, 1.0000))
        return p
    }
    // shape 5  fill=url(#radial3)
    static func shape5(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: pt(r, 0.6059, 0.9999))
        p.addLine(to: pt(r, 0.2171, 0.9999))
        p.addCurve(to: pt(r, 0.0526, 0.8262), control1: pt(r, 0.1262, 0.9999), control2: pt(r, 0.0526, 0.9222))
        p.addLine(to: pt(r, 0.0526, 0.3364))
        p.addCurve(to: pt(r, 0.0890, 0.4061), control1: pt(r, 0.0526, 0.3647), control2: pt(r, 0.0664, 0.3910))
        p.addLine(to: pt(r, 0.6637, 0.7888))
        p.addCurve(to: pt(r, 0.7142, 0.8856), control1: pt(r, 0.6952, 0.8097), control2: pt(r, 0.7142, 0.8463))
        p.addCurve(to: pt(r, 0.6059, 0.9999), control1: pt(r, 0.7142, 0.9487), control2: pt(r, 0.6658, 0.9999))
        p.closeSubpath()
        p.move(to: pt(r, 0.6059, 0.9999))
        return p
    }
    // shape 6  fill=url(#radial4)
    static func shape6(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: pt(r, 0.0855, 0.4718))
        p.addLine(to: pt(r, 0.3355, 0.4718))
        p.addCurve(to: pt(r, 0.4210, 0.5621), control1: pt(r, 0.3828, 0.4718), control2: pt(r, 0.4210, 0.5122))
        p.addLine(to: pt(r, 0.4210, 0.8262))
        p.addCurve(to: pt(r, 0.3355, 0.9165), control1: pt(r, 0.4210, 0.8760), control2: pt(r, 0.3828, 0.9165))
        p.addLine(to: pt(r, 0.0855, 0.9165))
        p.addCurve(to: pt(r, 0.0000, 0.8262), control1: pt(r, 0.0383, 0.9165), control2: pt(r, 0.0000, 0.8760))
        p.addLine(to: pt(r, 0.0000, 0.5621))
        p.addCurve(to: pt(r, 0.0855, 0.4718), control1: pt(r, 0.0000, 0.5122), control2: pt(r, 0.0383, 0.4718))
        p.closeSubpath()
        p.move(to: pt(r, 0.0855, 0.4718))
        return p
    }
    // shape 7  fill=rgb(100%,100%,100%)
    static func shape7(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: pt(r, 0.2094, 0.8220))
        p.addCurve(to: pt(r, 0.1237, 0.7875), control1: pt(r, 0.1746, 0.8220), control2: pt(r, 0.1460, 0.8105))
        p.addCurve(to: pt(r, 0.0902, 0.6974), control1: pt(r, 0.1014, 0.7645), control2: pt(r, 0.0902, 0.7344))
        p.addCurve(to: pt(r, 0.1242, 0.6025), control1: pt(r, 0.0902, 0.6583), control2: pt(r, 0.1015, 0.6267))
        p.addCurve(to: pt(r, 0.2133, 0.5663), control1: pt(r, 0.1469, 0.5783), control2: pt(r, 0.1766, 0.5663))
        p.addCurve(to: pt(r, 0.2980, 0.6010), control1: pt(r, 0.2480, 0.5663), control2: pt(r, 0.2763, 0.5778))
        p.addCurve(to: pt(r, 0.3309, 0.6924), control1: pt(r, 0.3199, 0.6241), control2: pt(r, 0.3309, 0.6546))
        p.addCurve(to: pt(r, 0.2969, 0.7864), control1: pt(r, 0.3309, 0.7313), control2: pt(r, 0.3195, 0.7626))
        p.addCurve(to: pt(r, 0.2094, 0.8220), control1: pt(r, 0.2743, 0.8101), control2: pt(r, 0.2452, 0.8220))
        p.closeSubpath()
        p.move(to: pt(r, 0.2105, 0.7732))
        p.addCurve(to: pt(r, 0.2563, 0.7526), control1: pt(r, 0.2294, 0.7732), control2: pt(r, 0.2447, 0.7663))
        p.addCurve(to: pt(r, 0.2736, 0.6955), control1: pt(r, 0.2678, 0.7389), control2: pt(r, 0.2736, 0.7199))
        p.addCurve(to: pt(r, 0.2568, 0.6361), control1: pt(r, 0.2736, 0.6701), control2: pt(r, 0.2680, 0.6503))
        p.addCurve(to: pt(r, 0.2118, 0.6149), control1: pt(r, 0.2455, 0.6220), control2: pt(r, 0.2305, 0.6149))
        p.addCurve(to: pt(r, 0.1651, 0.6368), control1: pt(r, 0.1925, 0.6149), control2: pt(r, 0.1769, 0.6222))
        p.addCurve(to: pt(r, 0.1475, 0.6945), control1: pt(r, 0.1533, 0.6513), control2: pt(r, 0.1475, 0.6705))
        p.addCurve(to: pt(r, 0.1651, 0.7521), control1: pt(r, 0.1475, 0.7187), control2: pt(r, 0.1533, 0.7380))
        p.addCurve(to: pt(r, 0.2105, 0.7732), control1: pt(r, 0.1769, 0.7661), control2: pt(r, 0.1920, 0.7732))
        p.closeSubpath()
        p.move(to: pt(r, 0.2105, 0.7732))
        return p
    }
    // shape 8  fill=rgb(100%,100%,100%)
    static func shape8(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: pt(r, 0.2093, 0.8254))
        p.addCurve(to: pt(r, 0.1239, 0.7900), control1: pt(r, 0.1747, 0.8254), control2: pt(r, 0.1462, 0.8136))
        p.addCurve(to: pt(r, 0.0905, 0.6974), control1: pt(r, 0.1017, 0.7663), control2: pt(r, 0.0905, 0.7355))
        p.addCurve(to: pt(r, 0.1244, 0.6000), control1: pt(r, 0.0905, 0.6573), control2: pt(r, 0.1018, 0.6248))
        p.addCurve(to: pt(r, 0.2132, 0.5627), control1: pt(r, 0.1470, 0.5751), control2: pt(r, 0.1766, 0.5627))
        p.addCurve(to: pt(r, 0.2976, 0.5984), control1: pt(r, 0.2478, 0.5627), control2: pt(r, 0.2759, 0.5746))
        p.addCurve(to: pt(r, 0.3303, 0.6923), control1: pt(r, 0.3194, 0.6221), control2: pt(r, 0.3303, 0.6534))
        p.addCurve(to: pt(r, 0.2964, 0.7889), control1: pt(r, 0.3303, 0.7322), control2: pt(r, 0.3190, 0.7644))
        p.addCurve(to: pt(r, 0.2093, 0.8254), control1: pt(r, 0.2739, 0.8132), control2: pt(r, 0.2449, 0.8254))
        p.closeSubpath()
        p.move(to: pt(r, 0.2103, 0.7753))
        p.addCurve(to: pt(r, 0.2560, 0.7542), control1: pt(r, 0.2293, 0.7753), control2: pt(r, 0.2445, 0.7682))
        p.addCurve(to: pt(r, 0.2733, 0.6955), control1: pt(r, 0.2675, 0.7401), control2: pt(r, 0.2733, 0.7205))
        p.addCurve(to: pt(r, 0.2565, 0.6345), control1: pt(r, 0.2733, 0.6694), control2: pt(r, 0.2677, 0.6491))
        p.addCurve(to: pt(r, 0.2117, 0.6127), control1: pt(r, 0.2453, 0.6200), control2: pt(r, 0.2304, 0.6127))
        p.addCurve(to: pt(r, 0.1652, 0.6352), control1: pt(r, 0.1924, 0.6127), control2: pt(r, 0.1770, 0.6202))
        p.addCurve(to: pt(r, 0.1476, 0.6944), control1: pt(r, 0.1535, 0.6501), control2: pt(r, 0.1476, 0.6699))
        p.addCurve(to: pt(r, 0.1652, 0.7536), control1: pt(r, 0.1476, 0.7194), control2: pt(r, 0.1535, 0.7391))
        p.addCurve(to: pt(r, 0.2103, 0.7753), control1: pt(r, 0.1770, 0.7680), control2: pt(r, 0.1920, 0.7753))
        p.closeSubpath()
        p.move(to: pt(r, 0.2103, 0.7753))
        return p
    }
}

/// The mark, drawn at whatever size it is given.
///
/// Paint order is the SVG's document order, which is the only order that
/// produces the fold: the three diagonal bands go down first, then the two cyan
/// wings cover their lower halves, then the badge. Shape 3 is not a body panel
/// at all — its gradient runs from fully transparent to dark, so it is the
/// shadow the flaps cast, and painting it as a solid was part of what made the
/// hand-drawn versions read as flat.
struct OutlookMarkView: View {
    var body: some View {
        GeometryReader { geo in
            let r = CGRect(origin: .zero, size: geo.size)
            ZStack {
                OutlookMark.shape0(in: r).fill(
                    LinearGradient(stops: [
                        .init(color: Color(red: 0.125, green: 0.655, blue: 0.980), location: 0),
                        .init(color: Color(red: 0.231, green: 0.835, blue: 1.000), location: 0.40),
                        .init(color: Color(red: 0.769, green: 0.690, blue: 1.000), location: 1),
                    ], startPoint: .bottomLeading, endPoint: .topTrailing))

                OutlookMark.shape1(in: r).fill(
                    LinearGradient(stops: [
                        .init(color: Color(red: 0.086, green: 0.353, blue: 0.851), location: 0),
                        .init(color: Color(red: 0.094, green: 0.502, blue: 0.898), location: 0.50),
                        .init(color: Color(red: 0.522, green: 0.529, blue: 1.000), location: 1),
                    ], startPoint: .bottomLeading, endPoint: .topTrailing))

                OutlookMark.shape2(in: r).fill(
                    LinearGradient(stops: [
                        .init(color: Color(red: 0.102, green: 0.263, blue: 0.651), location: 0),
                        .init(color: Color(red: 0.125, green: 0.322, blue: 0.796), location: 0.49),
                        .init(color: Color(red: 0.373, green: 0.125, blue: 0.796), location: 1),
                    ], startPoint: .bottomLeading, endPoint: .topTrailing))

                // The cast shadow: transparent at the centre, dark at the edge.
                OutlookMark.shape3(in: r).fill(
                    RadialGradient(stops: [
                        .init(color: Color(red: 0.153, green: 0.373, blue: 0.941).opacity(0), location: 0.57),
                        .init(color: Color(red: 0.000, green: 0.129, blue: 0.467).opacity(1), location: 0.99),
                    ], center: .top, startRadius: 0, endRadius: max(r.width, r.height)))

                OutlookMark.shape4(in: r).fill(
                    LinearGradient(stops: [
                        .init(color: Color(red: 0.302, green: 0.769, blue: 1.000), location: 0),
                        .init(color: Color(red: 0.059, green: 0.686, blue: 1.000), location: 0.20),
                    ], startPoint: .bottomTrailing, endPoint: .topLeading))

                OutlookMark.shape5(in: r).fill(
                    RadialGradient(stops: [
                        .init(color: Color(red: 0.286, green: 0.871, blue: 1.000), location: 0),
                        .init(color: Color(red: 0.161, green: 0.765, blue: 1.000), location: 0.72),
                    ], center: .bottomLeading, startRadius: 0, endRadius: r.width))

                OutlookMark.shape6(in: r).fill(
                    RadialGradient(stops: [
                        .init(color: Color(red: 0.000, green: 0.569, blue: 1.000), location: 0.04),
                        .init(color: Color(red: 0.094, green: 0.239, blue: 0.678), location: 0.92),
                    ], center: .topTrailing, startRadius: 0, endRadius: r.width * 0.6))

                OutlookMark.shape7(in: r).fill(.white)
            }
        }
    }
}

#if DEBUG
/// `-mark outlook` → the mark alone on parchment, big enough to compare against
/// the reference render.
///
/// **This exists because three wrong versions shipped without being looked
/// at.** The mark is drawn in the source picker and the connected bars, both
/// behind a signed-in session that a simulator does not have, so the only way
/// it was ever checked was by describing it. `tools/outlook_mark_check.py`
/// reads the screenshot this produces.
struct OutlookMarkDebugView: View {
    var body: some View {
        ZStack {
            Color(red: 0.953, green: 0.937, blue: 0.914).ignoresSafeArea()
            OutlookMarkView().frame(width: 300, height: 285)
        }
    }
}
#endif
