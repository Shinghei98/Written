import SwiftUI

/// Four-point stars, breathing slowly. Decoration only — they carry no data.
struct SparkleView: View {
    var size: CGFloat = 14
    var delay: Double = 0

    @State private var isBright = false

    var body: some View {
        SparkleShape()
            .stroke(GardenPalette.softInk, lineWidth: max(0.7, size * 0.055))
            .frame(width: size, height: size)
            .opacity(isBright ? 0.55 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever().delay(delay)) {
                    isBright = true
                }
            }
            .allowsHitTesting(false)
    }
}

struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let arm = min(rect.width, rect.height) / 2
        let waist = arm * 0.22

        path.move(to: CGPoint(x: centre.x, y: centre.y - arm))
        path.addQuadCurve(to: CGPoint(x: centre.x + arm, y: centre.y), control: CGPoint(x: centre.x + waist, y: centre.y - waist))
        path.addQuadCurve(to: CGPoint(x: centre.x, y: centre.y + arm), control: CGPoint(x: centre.x + waist, y: centre.y + waist))
        path.addQuadCurve(to: CGPoint(x: centre.x - arm, y: centre.y), control: CGPoint(x: centre.x - waist, y: centre.y + waist))
        path.addQuadCurve(to: CGPoint(x: centre.x, y: centre.y - arm), control: CGPoint(x: centre.x - waist, y: centre.y - waist))
        return path
    }
}
