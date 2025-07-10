import SwiftUI

// MARK: – Data Models

struct LeaderboardUser: Identifiable {
    let id = UUID()
    let name: String
    let puffsReduced: Int
    let avatarColor: Color  // placeholder for avatar background
    let rank: Int           // 1 through N
}

struct GroupMember: Identifiable {
    let id = UUID()
    let name: String
    let puffsReduced: Int
    let avatarColor: Color
}

// MARK: – Main View

struct LeaderboardView: View {
    // Dummy leaderboard data (top 5)
    private let leaderboard: [LeaderboardUser] = [
        .init(name: "Ethan Carter",    puffsReduced: 1200, avatarColor: .green,   rank: 1),
        .init(name: "Liam Harper",     puffsReduced: 1150, avatarColor: .purple, rank: 2),
        .init(name: "Noah Bennett",    puffsReduced: 1100, avatarColor: .orange, rank: 3),
        .init(name: "Oliver Hayes",    puffsReduced: 1050, avatarColor: .pink,   rank: 4),
        .init(name: "Elijah Foster",   puffsReduced: 1000, avatarColor: .yellow, rank: 5)
    ]
    
    // Dummy group progress data
    private let groupMembers: [GroupMember] = [
        .init(name: "You",            puffsReduced:  950, avatarColor: .green),
        .init(name: "Lucas Coleman",  puffsReduced:  900, avatarColor: .red),
        .init(name: "Mason Brooks",   puffsReduced:  850, avatarColor: .gray),
        .init(name: "Logan Murphy",   puffsReduced:  800, avatarColor: .teal)
    ]
    
    // Dummy group‐level stats
    private let totalPuffsReduced = 2350
    private let longestStreakDays = 15
    
    var body: some View {
        ZStack {
            // Background color (dark green/black)
            Color(red: 18/255, green: 24/255, blue: 22/255)
                .ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    
                    // ← Back button & Title
                    HStack {
                        Button(action: {
                            // handle back action
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 16)
                    
                    Text("Leaderboard")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal)
                    
                    // MARK: – Top Puff Reducers
                    Text("Top Puff Reducers")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal)
                    
                    VStack(spacing: 12) {
                        ForEach(leaderboard) { user in
                            LeaderboardRow(user: user)
                        }
                    }
                    .padding(.horizontal)
                    
                    // MARK: – Group Progress Section
                    Text("Group Progress")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal)
                        .padding(.top, 16)
                    
                    VStack(spacing: 16) {
                        // Group Card Header (Nicotine Navigators + metrics)
                        GroupCardHeaderView(
                            groupName: "Nicotine Navigators",
                            totalPuffs: totalPuffsReduced,
                            longestStreak: longestStreakDays
                        )
                        
                        // Individual group members with progress bars
                        VStack(spacing: 12) {
                            ForEach(groupMembers) { member in
                                GroupMemberRow(member: member, maxPuffs: 1000)
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    Spacer(minLength: 40)
                }
            }
        }
    }
}

// MARK: – Leaderboard Row

struct LeaderboardRow: View {
    let user: LeaderboardUser
    
    // Use @ViewBuilder so that Image and Text branches produce a consistent 'some View'
    @ViewBuilder
    private var medalView: some View {
        switch user.rank {
        case 1:
            Image(systemName: "rosette")
                .foregroundColor(.yellow)
                .font(.title2)
        case 2:
            Image(systemName: "rosette")
                .foregroundColor(.gray)
                .font(.title2)
        case 3:
            Image(systemName: "rosette")
                .foregroundColor(.brown)
                .font(.title2)
        default:
            Text("\(user.rank)")
                .font(.headline)
                .foregroundColor(.white.opacity(0.7))
        }
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // Avatar placeholder
            Circle()
                .fill(user.avatarColor)
                .frame(width: 50, height: 50)
                .overlay(
                    Text(String(user.name.prefix(1)))
                        .font(.headline)
                        .foregroundColor(.white)
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(user.name)
                    .font(.headline)
                    .foregroundColor(.white)
                Text("\(user.puffsReduced) puffs reduced")
                    .font(.subheadline)
                    .foregroundColor(.green)
            }
            Spacer()
            
            medalView
        }
        .padding()
        .background(Color(red: 25/255, green: 32/255, blue: 28/255))
        .cornerRadius(12)
    }
}

// MARK: – Group Card Header

struct GroupCardHeaderView: View {
    let groupName: String
    let totalPuffs: Int
    let longestStreak: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(groupName)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Spacer()
                Text("View All")
                    .font(.subheadline)
                    .foregroundColor(.green)
            }
            
            HStack(spacing: 16) {
                VStack {
                    Text("\(totalPuffs)")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                    Text("Total Puffs Reduced")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
                Spacer()
                VStack {
                    Text("\(longestStreak)")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                    Text("Longest Vape-Free Streak")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
                Spacer()
            }
        }
        .padding()
        .background(Color(red: 25/255, green: 32/255, blue: 28/255))
        .cornerRadius(12)
    }
}

// MARK: – Group Member Row

struct GroupMemberRow: View {
    let member: GroupMember
    let maxPuffs: Double   // e.g. maximum possible (1000) to calculate bar progress
    
    var body: some View {
        HStack(spacing: 16) {
            // Avatar placeholder
            Circle()
                .fill(member.avatarColor)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(member.name.prefix(1)))
                        .font(.subheadline)
                        .foregroundColor(.white)
                )
            
            Text(member.name)
                .font(.body)
                .foregroundColor(.white)
            
            Spacer()
            
            Text("\(member.puffsReduced) puffs")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
            
            // Progress bar (scaled to maxPuffs)
            ProgressView(value: Double(member.puffsReduced), total: maxPuffs)
                .tint(.green)
                .frame(width: 100)
        }
        .padding(.vertical, 4)
    }
}

// MARK: – Preview

struct LeaderboardView_Previews: PreviewProvider {
    static var previews: some View {
        LeaderboardView()
    }
}
