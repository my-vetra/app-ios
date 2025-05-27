import SwiftUI

struct RippleEffectView: View {
    @State private var animateRipple = false // Controls the ripple animation

    var body: some View {
        ZStack {
            ForEach(0..<2) { i in
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: animateRipple ? 0.5 : 8) // Starts thick, thins out
                    .frame(width: 150, height: 150)
                    .scaleEffect(animateRipple ? 2.2 : 1) // Expand effect
                    .opacity(animateRipple ? 0 : 1) // Fade out effect
                    .animation(
                        Animation.easeOut(duration: 2.5)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i)),
                        value: animateRipple
                    )
            }

            Image(systemName: "flame.fill") // Replace with actual logo
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .opacity(0.5)
        }
        .frame(width: 200, height: 200)
        .onAppear {
            animateRipple = true
        }
    }
}

#Preview {
    RippleEffectView()
        .background(.teal)
}
