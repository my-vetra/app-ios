import SwiftUI

struct LockView: View {
    var size: CGFloat // Dynamic lock size
    var color: Color
    @State private var fadeInOut = false // Controls fade animation

    var body: some View {
        ZStack {
            // Lock Icon with Fade Animation
            Image(systemName: "lock.fill")
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.4, height: size * 0.4) // 40% of the arc size
                .foregroundColor(color)
                .opacity(fadeInOut ? 1 : 0.5) // Fades in and out
                .animation(
                    Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                    value: fadeInOut
                )
        }
        .frame(width: size, height: size)
        .onAppear {
            fadeInOut = true
        }
    }
}

struct UnlockView: View {
    var size: CGFloat // Dynamic lock size
    var color: Color

    var body: some View {
        ZStack {
            // Lock Icon with Fade Animation
            Image(systemName: "lock.open.fill")
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.4, height: size * 0.4) // 40% of the arc size
                .foregroundColor(color)
        }
        .frame(width: size, height: size)
    }
}

// Custom Arc Shape with Rounded Edges
struct ArcShape: Shape {
    var startAngle: Double
    var endAngle: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(startAngle),
            endAngle: .degrees(endAngle),
            clockwise: false
        )
        return path
    }
}

#Preview {
    Group {
        LockView(size: 200, color: .mint) // Testing with different sizes
        UnlockView(size: 200, color: .green) // Testing with different sizes
    }
    // Arc Preview not shown
}
