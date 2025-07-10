import SwiftUI

struct SettingsView: View {
    var body: some View {
        ZStack {
            // 1) Background Color
            Color(red: 18/255, green: 24/255, blue: 22/255)
                .ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    
                    // 2) Back Button + Title
                    HStack {
                        Button(action: {
                            // handle back navigation here
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 16)
                    
                    Text("Vape-Free Journey")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal)
                    
                    // 3) Profile Avatar + Name + Subtitle
                    VStack(alignment: .center, spacing: 8) {
                        ZStack {
                            // Outer circle (green border)
                            Circle()
                                .stroke(Color.green, lineWidth: 4)
                                .frame(width: 120, height: 120)
                            
                            // Inner circle (avatar placeholder)
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 110, height: 110)
                                .overlay(
                                    Text("E")
                                        .font(.largeTitle)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                )
                            
                            // Small badge icon (bottom-right)
                            Circle()
                                .fill(Color.green)
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Image(systemName: "leaf.fill")
                                        .resizable()
                                        .scaledToFit()
                                        .padding(6)
                                        .foregroundColor(.black)
                                )
                                .offset(x: 50, y: 50)
                        }
                        
                        Text("Ethan Carter")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                        
                        Text("Vape-Free for 30 Days")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    
                    // 4) Three Stat Cards
                    HStack(spacing: 12) {
                        StatCardView(number: "1500", label: "Puffs Reduced")
                        StatCardView(number: "30", label: "Days Vape-Free")
                        StatCardView(number: "$150", label: "Saved")
                    }
                    .padding(.horizontal)
                    
                    // 5) Milestones Section
                    Text("Milestones")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal)
                    
                    VStack(spacing: 0) {
                        // First Milestone
                        MilestoneRow(
                            iconName: "calendar",
                            title: "Started Nicotine Pouches",
                            dateText: "May 15, 2024",
                            isFirst: true,
                            isLast: false
                        )
                        
                        // Second Milestone
                        MilestoneRow(
                            iconName: "trophy",
                            title: "1000 Puffs Reduced",
                            dateText: "June 10, 2024",
                            isFirst: false,
                            isLast: false
                        )
                        
                        // Third Milestone
                        MilestoneRow(
                            iconName: "star.fill",
                            title: "30 Days Vape-Free",
                            dateText: "July 15, 2024",
                            isFirst: false,
                            isLast: true
                        )
                    }
                    .padding(.horizontal)
                    
                    // 6) (Optional) Updates Title / Placeholder
                    Text("Updates")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal)
                    
                    // If you want to show some scrolling update text, uncomment below:
                    // VStack(alignment: .leading) {
                    //     Text("🎉 You just hit 30 days, Ethan! Keep it going!").foregroundColor(.white)
                    //     Text("💬 Thanks for the support, everyone!").foregroundColor(.white)
                    // }
                    // .padding()
                    // .background(Color(red: 25/255, green: 32/255, blue: 28/255))
                    // .cornerRadius(12)
                    // .padding(.horizontal)
                    
                    Spacer(minLength: 40)
                }
            }
        }
    }
}

// MARK: – Stat Card

fileprivate struct StatCardView: View {
    let number: String
    let label: String
    
    var body: some View {
        VStack(spacing: 4) {
            Text(number)
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.green)
            Text(label)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(red: 25/255, green: 32/255, blue: 28/255))
        .cornerRadius(12)
    }
}

// MARK: – Milestone Row

fileprivate struct MilestoneRow: View {
    let iconName: String
    let title: String
    let dateText: String
    let isFirst: Bool
    let isLast: Bool
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline icon + vertical connector
            VStack(spacing: 0) {
                // Icon circle
                Circle()
                    .fill(Color.green)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: iconName)
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(.black)
                            .padding(6)
                    )
                
                // Vertical line below, unless this is the last milestone
                if !isLast {
                    Rectangle()
                        .fill(Color.green)
                        .frame(width: 2, height: 48)
                        .offset(y: -2)
                }
            }
            
            // Title + Date
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Text(dateText)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Spacer()
        }
        .padding(.vertical, isFirst ? 4 : 12)
    }
}

// MARK: – Preview

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
