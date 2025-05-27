import SwiftUI
import Charts

// 1) Your data model
struct PuffData: Identifiable {
    let id = UUID()
    let date: Date
    let puffs: Int
}

struct ProgressView: View {
    // 2) Dummy data for the past 7 days
    private let data: [PuffData] = {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // replace these with your actual puff-counts
        let dummyCounts = [12, 8, 10, 15, 7, 5, 9]
        return (0..<7).map { i in
            let day = cal.date(byAdding: .day, value: -6 + i, to: today)!
            return PuffData(date: day, puffs: dummyCounts[i])
        }
    }()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text("Puffs in the Last 7 Days")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding(.horizontal)

                Chart(data) { entry in
                    BarMark(
                        x: .value("Day", entry.date, unit: .day),
                        y: .value("Puffs", entry.puffs)
                    )
                    .foregroundStyle(Color.green)
                }
                .chartXAxis {
                    AxisMarks(values: data.map { $0.date }) { value in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                            .foregroundStyle(.white)
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text("\(v)")
                            }
                        }
                        .foregroundStyle(.white)
                    }
                }
                .frame(height: 200)
                .padding()
                .background(Color(.darkGray))
                .cornerRadius(12)
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
        }
    }
}

struct ProgressView_Previews: PreviewProvider {
    static var previews: some View {
        ProgressView()
    }
}
