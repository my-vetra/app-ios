// MainViewModel.swift
import SwiftUI
import Combine
import CoreData

enum TimerState {
    case locked
    case unlocked
}


class MainViewModel: ObservableObject {
    @Published var state: TimerState = .locked
    @Published var progress: Double    = 0
    @Published var ratioString: String = "0/0"
    @Published var timeProgress: Double    = 0
    @Published var timeRemainingString: String = "--"
    @Published var username: String = ""
    @Published var devicename: String = ""
    @Published var connected: Bool = false
    @Published var currentPhaseIndex: Int = 0

    private var session: SessionLifetimeModel?
    private var active: PhaseModel?

    private var cancellables = Set<AnyCancellable>()

    private let sessionRepo: SessionLifetimeRepositoryProtocol
    private let phaseRepo:  PhaseRepositoryProtocol

    init(context: NSManagedObjectContext) {
        self.sessionRepo = SessionLifetimeRepositoryCoreData(context: context)
        self.phaseRepo  = PhaseRepositoryCoreData(context: context)

        bind()
        startTimer()
    }

    private func bind() {
        sessionRepo.loadSession()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sess in
                self?.session = sess
                self?.recompute()
            }
            .store(in: &cancellables)

        phaseRepo.loadActivePhase()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.active = active
                self?.recompute()
            }
            .store(in: &cancellables)
    }

    private func startTimer() {
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
        
        // Count puffs that belong to the current phase (puffs carry phaseIndex)
        let taken = active.puffsTaken
        let maxP  = active.maxPuffs

        state = (taken >= maxP) ? .locked : .unlocked
        username = session.userId
        currentPhaseIndex = active.phaseIndex

        progress    = Double(min(taken, maxP)) / Double(maxP)
        ratioString = "\(min(taken, maxP))/\(maxP)"
        recomputeTime()
    }

    private func recomputeTime() {
        guard let session = session,
              let active  = active,
              let startDate = active.startDate,
              session.allPhases.indices.contains(active.phaseIndex)
        else {
            timeRemainingString = Self.formatTime(0)
            return
        }

        let phase    = session.allPhases[active.phaseIndex]
        let elapsed  = Date().timeIntervalSince(startDate)
        let duration = phase.duration

        timeProgress = min(max(elapsed / duration, 0), 1)

        let remain = max(duration - elapsed, 0)
        if remain <= 0 {
            return
        }

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
