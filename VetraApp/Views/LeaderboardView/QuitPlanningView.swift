import SwiftUI
import Charts

// MARK: – Data Models for Chart

struct LimitData: Identifiable {
    let id = UUID()
    let day: Int
    let value: Int
}

struct TakenData: Identifiable {
    let id = UUID()
    let day: Int
    let value: Int
}

// MARK: – Main Quitting Plan View

struct QuittingPlanView: View {
    // Dummy countdown values (static for now)
    private let daysLeft = 4
    private let hoursLeft = 23
    private let minutesLeft = 59
    private let secondsLeft = 03
    
    // Dummy chart data (day 1 through 6)
    private let limitSeries: [LimitData] = [
        .init(day: 1, value: 186),
        .init(day: 2, value: 160),
        .init(day: 3, value: 120),
        .init(day: 4, value:  80),
        .init(day: 5, value:  50),
        .init(day: 6, value:  0),
    ]

    private let takenSeries: [TakenData] = [
        .init(day: 1, value: 93),
        .init(day: 2, value: 60),
        .init(day: 3, value: 40),
        .init(day: 4, value: 25),
        .init(day: 5, value: 10),
        .init(day: 6, value: 0),
    ]
    
    // Assume daily limit is the first value in limitSeries
    private var dailyLimit: Int { limitSeries.first?.value ?? 0 }
    // Taken so far today (dummy)
    private var takenToday: Int { takenSeries.first?.value ?? 0 }
    private var leftToday: Int { max(dailyLimit - takenToday, 0) }
    
    // Dark background colors
    private var darkMint: Color {
        Color(red: 18/255, green: 24/255, blue: 22/255)
    }
    private var accentGreen: Color {
        Color.green
    }

    var body: some View {
        ZStack {
            // 1) Full‐screen dark‐mint background
            darkMint
                .ignoresSafeArea()
            
            ScrollView{
                VStack(spacing: 16) {
                    // 2) Top bar: Back chevron + Title
                    HStack {
                        Button(action: {
                            // Handle back action here
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 16)
                    
                    Text("Quitting Plan")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    // 3) Day Badge
                    HStack(spacing: 8) {
                        Image(systemName: "hourglass")
                            .foregroundColor(.white)
                        Text("DAY 1")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(accentGreen.opacity(0.8))
                    .cornerRadius(8)
                    
                    // 4) Countdown Timer
                    Text("Quitting in")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white.opacity(0.8))
                    
                    HStack(spacing: 12) {
                        TimerBlock(number: daysLeft, label: "Days")
                        TimerBlock(number: hoursLeft, label: "Hours")
                        TimerBlock(number: minutesLeft, label: "Minutes")
                        TimerBlock(number: secondsLeft, label: "Seconds")
                    }
                    
                    Text("Strive to keep your daily puffs below the green limit each day.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 4)
                    
                    // 5) Chart Container
                    VStack {
                        Chart {
                            // —————— 1) “Limit” series (white, smooth, no symbols) ——————
//                            ForEach(limitSeries) { point in
//                                    LineMark(
//                                        x: .value("Day", point.day),
//                                        y: .value("Limit", point.value)
//                                    )
//                                    .interpolationMethod(.monotone)
//                                    .foregroundStyle(.white)
//                                    .lineStyle(StrokeStyle(lineWidth: 3))
//                                }

                                // —————— 2) “Taken” series (gray dashed + explicit dots) ——————
                                ForEach(takenSeries) { point in
                                    LineMark(
                                        x: .value("Day", point.day),
                                        y: .value("Taken", point.value)
                                    )
                                    .interpolationMethod(.monotone)
                                    .foregroundStyle(.gray)
                                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [6]))
                                    
                                    PointMark(
                                        x: .value("Day", point.day),
                                        y: .value("Taken", point.value)
                                    )
                                    .symbolSize(80)
                                    .foregroundStyle(.gray)
                                }
                            }
                        .chartYScale(domain: 0...200)
                        .chartXAxis {
                            AxisMarks(values: takenSeries.map { $0.day }) { value in
                                if let day = value.as(Int.self) {
                                    AxisValueLabel {
                                        Text("\(day)")
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                }
                            }
                        }
                        .chartYAxis {
                            AxisMarks(preset: .aligned, position: .leading) { value in
                                AxisValueLabel {
                                    if let val = value.as(Int.self) {
                                        Text("\(val)")
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                }
                            }
                        }
                        .frame(height: 240)
                        .padding()

                    }
                    .background(Color(red: 20/255, green: 28/255, blue: 24/255))
                    .cornerRadius(16)
                    .padding(.horizontal, 16)
                    
                    // 6) “Slide to see more”
                    Text("Slide to see more")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.top, 8)
                    
                    // 7) Puffs left for today / Daily Limit
                    VStack(spacing: 4) {
                        Text("\(leftToday)")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundColor(accentGreen)
                        Text("Puffs left for today")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                        Text("/ \(dailyLimit) Puffs")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.top, 8)
                    
                    Spacer()
                    
//                    // 8) Bottom Navigation Bar
//                    HStack {
//                        NavButton(icon: "house.fill", isSelected: false)
//                        Spacer()
//                        NavButton(icon: "chart.bar.fill", isSelected: false)
//                        Spacer()
//                        NavButton(icon: "flag.fill", isSelected: true) // current tab
//                        Spacer()
//                        NavButton(icon: "person.fill", isSelected: false)
//                        Spacer()
//                        NavButton(icon: "questionmark.circle.fill", isSelected: false)
//                    }
//                    .padding(.horizontal, 32)
//                    .padding(.vertical, 12)
//                    .background(Color(red: 15/255, green: 22/255, blue: 18/255).opacity(0.9))
//                    .cornerRadius(16)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

// MARK: – TimerBlock

fileprivate struct TimerBlock: View {
    let number: Int
    let label: String
    
    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%02d", number))
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(width: 60, height: 60)
        .background(Color(red: 20/255, green: 28/255, blue: 24/255))
        .cornerRadius(8)
    }
}

// MARK: – NavButton

fileprivate struct NavButton: View {
    let icon: String
    let isSelected: Bool
    
    var body: some View {
        if isSelected {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.8))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
            }
        } else {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.white.opacity(0.7))
        }
    }
}

// MARK: – Preview

struct QuittingPlanView_Previews: PreviewProvider {
    static var previews: some View {
        QuittingPlanView()
    }
}



