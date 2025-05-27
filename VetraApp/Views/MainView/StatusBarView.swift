import SwiftUI

struct DeviceStatusBar: View {
    var color: Color
    var label: String
    var progress: CGFloat

    var body: some View {
        VStack(alignment: .center) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(.white)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background Bar
                    RoundedRectangle(cornerRadius: 5)
                        .frame(height: 10)
                        .foregroundColor(color.opacity(0.4))

                    // Foreground Progress Bar (Mint)
                    RoundedRectangle(cornerRadius: 5)
                        .frame(width: min(CGFloat(progress) * geometry.size.width, geometry.size.width),
                               height: 10)
                        .foregroundColor(color)
                        .animation(.easeInOut(duration: 0.7), value: progress)
                }
            }
            .frame(height: 10)
        }
        .frame(width: 140) // Adjusted width to fit inside HStack
        .padding(.vertical, 5)
    }
}

struct TimerArc: View {
    var state: TimerState
    var color: Color {
        return state == .locked ? .mint : .green
    }
    var gapAngle: Double = 50 // Change this to control the bottom gap size
    var progress: CGFloat
    var time: String

    

    var body: some View {
        
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let strokeWidth = size * 0.05
            let totalArc: Double = 360 - gapAngle
            let startAngle: Double = -270 + (gapAngle / 2)
            let endAngle: Double = startAngle + (Double(progress) * totalArc)

            ZStack {
                // Background Arc (Full Outline)
                ArcShape(startAngle: startAngle, endAngle: 90 - (gapAngle / 2))
                    .stroke(color.opacity(0.4), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))

                // Foreground Progress Arc (Now updates with high precision)
                ArcShape(startAngle: startAngle, endAngle: endAngle)
                    .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                    .animation(.easeInOut(duration: 1), value: progress) // Ensures smooth updates
                
                // Lock Animation at the Center (Dynamic Size)
                Group {
                    if state == .unlocked {
                        UnlockView(size: size, color: color)
                    } else {
                        LockView(size: size, color: color)
                    }
                }
                .transition(.opacity.combined(with: .scale))
                .animation(.easeInOut(duration: 0.7), value: color)
                
                                
                // Time Remaining Displayed in the Gap
                Text(time)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.gray)
                    .position(x: size / 2, y: size * 1) // Place at the bottom gap
            }
            .frame(width: size, height: size)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

#Preview {
    
    Group {
        TimerArc(state: .unlocked, progress: 0.1, time: "1h")
                .frame(width: 200, height: 200)
        HStack(spacing: 20) {
            DeviceStatusBar(color: .mint, label: "Juice", progress: 0.75)
            DeviceStatusBar(color: .mint, label: "Battery", progress: 0.5)
        }
        .padding()
    }
}
