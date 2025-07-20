import SwiftUI
import Combine

class MainViewModel: ObservableObject {
    // 🔗 Driven by session + active
    @Published var state: TimerState = .locked
    @Published var progress: Double    = 0     // puffsTaken/maxPuffs
    @Published var ratioString: String = "0/0" // e.g. "3/5"
    @Published var timeProgress: Double    = 0     // elapsed/duration
    @Published var timeRemainingString: String = "--"
    @Published var username: String = ""
    @Published var currentPhaseIndex: Int = 0
    
    
    // 🔗 Underlying models
    private var session: SessionLifetimeModel?
    private var active: ActivePhaseModel?
    
    
    
    private var cancellables = Set<AnyCancellable>()
    
    // 🔗 inject repos
    private let sessionRepo: SessionLifetimeRepositoryProtocol
    private let activeRepo:  ActivePhaseRepositoryProtocol
    
    init(
      sessionRepo: SessionLifetimeRepositoryProtocol = SessionLifetimeRepositoryCoreData(),
      activeRepo:  ActivePhaseRepositoryProtocol = ActivePhaseRepositoryCoreData()
    ) {
        self.sessionRepo = sessionRepo
        self.activeRepo  = activeRepo
        
        bind()
        startTimer()
    }
    
    private func bind() {
        // 🔗 listen for session load
        sessionRepo.loadSession()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sess in
                self?.session = sess
                self?.recompute()
            }
            .store(in: &cancellables)
        
        // 🔗 listen for active phase
        activeRepo.loadActivePhase()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.active = active
                self?.recompute()
            }
            .store(in: &cancellables)
    }
    
    private func startTimer() {
        // 🔗 refresh timing every second
        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.recomputeTime() }
            .store(in: &cancellables)
    }
    
    private func recompute() {
        guard
          let session = session,
          let active  = active,
          session.allPhases.indices.contains(active.phaseIndex)
        else { return }
        
        let phase = session.allPhases[active.phaseIndex]
        let taken = phase.puffsTaken                   // 🔗 puffsTaken
        let maxP   = phase.maxPuffs
        
        // locked if we've hit the max
        state = (taken == maxP) ? .locked : .unlocked
        username = session.userId
        currentPhaseIndex = active.phaseIndex
        // puff‐ratio
        progress      = Double(taken) / Double(maxP)
        ratioString   = "\(taken)/\(maxP)"
        recomputeTime()
    }
    
    private func recomputeTime() {
        guard
          let session = session,
          let storedActive = active,
          session.allPhases.indices.contains(storedActive.phaseIndex)
        else { return }

        let phase    = session.allPhases[storedActive.phaseIndex]
        let elapsed  = Date().timeIntervalSince(storedActive.phaseStartDate)
        let duration = phase.duration

        // time-bar progress
        timeProgress = min(max(elapsed / duration, 0), 1)

        let remain = duration - elapsed

        // 🔄 phase rollover
        if remain <= 0 {
            // 1) build a new ActivePhaseModel
            var newActive = storedActive
            newActive.phaseIndex += 1
            newActive.phaseStartDate = Date()

            // 2) update BOTH your local property and the repo
            self.active = newActive
            activeRepo.saveActivePhase(newActive)

            // 3) fully recompute all derived UI state
            recompute()
            return
        }

        // only set this when we're still in the same phase
        timeRemainingString = Self.formatTime(remain)
    }

    
    private static func formatTime(_ t: TimeInterval) -> String {
        let s = Int(t)
        let h = s/3600, m = (s%3600)/60, sec = s%60
        if h>0     { return "\(h)h \(m)m" }
        else if m>0{ return "\(m)m \(sec)s" }
        else       { return "\(sec)s" }
    }
}
