import SwiftUI
import Combine
import CoreData
#if canImport(Charts)
import Charts
#endif

// MARK: - Models (Pure Swift)

struct Phase: Identifiable {
    let id: UUID
    let index: Int
    let duration: TimeInterval
    let maxPuffs: Int
}

struct PuffEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let duration: TimeInterval
    let phaseIndex: Int
}

struct SessionLifetime {
    let sessionId: UUID
    let userId: String
    let allPhases: [Phase]
    let startedAt: Date
    var totalPuffsTaken: Int
    var phasesCompleted: Int
}

struct ActivePhase {
    let phaseIndex: Int
    var phaseStartDate: Date
    var puffsTaken: Int
}

protocol PhaseRepositoryProtocol {
  func fetchPhases() -> AnyPublisher<[Phase], Never>
}
protocol SessionLifetimeRepositoryProtocol {
  func loadSession() -> AnyPublisher<SessionLifetime, Never>
}
protocol ActivePhaseRepositoryProtocol {
  func loadActivePhase() -> AnyPublisher<ActivePhase, Never>
  func saveActivePhase(_ active: ActivePhase)
}
protocol PuffRepositoryProtocol {
  func loadPuffs() -> AnyPublisher<[PuffEntry], Never>
  func addPuff(_ puff: PuffEntry)
}


// MARK: - Core Data Persistence Controller

let viewContext = PersistenceController.shared.container.viewContext

// MARK: - Core Data Repositories

class PhaseRepositoryCoreData: PhaseRepositoryProtocol {
    func fetchPhases() -> AnyPublisher<[Phase], Never> {
        Future { promise in
            let req: NSFetchRequest<PhaseEntity> = PhaseEntity.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(keyPath: \PhaseEntity.index, ascending: true)]
            do {
                let entities = try viewContext.fetch(req)
                let phases = entities.map { ent in
                    Phase(id: ent.id ?? UUID(),
                          index: Int(ent.index),
                          duration: ent.duration,
                          maxPuffs: Int(ent.maxPuffs))
                }
                promise(.success(phases))
            } catch {
                print("Fetch phases error: \(error)")
                promise(.success([]))
            }
        }
        .eraseToAnyPublisher()
    }
}

class SessionLifetimeRepositoryCoreData: SessionLifetimeRepositoryProtocol {
    func loadSession() -> AnyPublisher<SessionLifetime, Never> {
        Future { promise in
            let req: NSFetchRequest<SessionLifetimeEntity> = SessionLifetimeEntity.fetchRequest()
            req.fetchLimit = 1
            do {
                if let e = try viewContext.fetch(req).first {
                    let phaseReq: NSFetchRequest<PhaseEntity> = PhaseEntity.fetchRequest()
                    phaseReq.sortDescriptors = [NSSortDescriptor(keyPath: \PhaseEntity.index, ascending: true)]
                    let phaseEnts = try viewContext.fetch(phaseReq)
                    let phases = phaseEnts.map { ent in
                        Phase(id: ent.id ?? UUID(),
                              index: Int(ent.index),
                              duration: ent.duration,
                              maxPuffs: Int(ent.maxPuffs))
                    }
                    let sess = SessionLifetime(
                        sessionId: e.sessionId ?? UUID(),
                        userId: e.userId ?? "",
                        allPhases: phases,
                        startedAt: e.startedAt ?? Date(),
                        totalPuffsTaken: Int(e.totalPuffsTaken),
                        phasesCompleted: Int(e.phasesCompleted)
                    )
                    promise(.success(sess))
                } else {
                    promise(.success(SessionLifetime(
                        sessionId: UUID(),
                        userId: "",
                        allPhases: [],
                        startedAt: Date(),
                        totalPuffsTaken: 0,
                        phasesCompleted: 0
                    )))
                }
            } catch {
                print("Load session error: \(error)")
                promise(.success(SessionLifetime(
                    sessionId: UUID(),
                    userId: "",
                    allPhases: [],
                    startedAt: Date(),
                    totalPuffsTaken: 0,
                    phasesCompleted: 0
                )))
            }
        }
        .eraseToAnyPublisher()
    }
}

class ActivePhaseRepositoryCoreData: ActivePhaseRepositoryProtocol {
    private let subject = CurrentValueSubject<ActivePhase, Never>(ActivePhase(phaseIndex: 0,
                                                                                  phaseStartDate: Date(),
                                                                                  puffsTaken: 0))

    init() { loadFromStore() }

    private func loadFromStore() {
        let req: NSFetchRequest<ActivePhasesEntity> = ActivePhasesEntity.fetchRequest()
        req.fetchLimit = 1
        if let ent = try? viewContext.fetch(req).first {
            let ap = ActivePhase(
                phaseIndex: Int(ent.phaseIndex),
                phaseStartDate: ent.phaseStartDate ?? Date(),
                puffsTaken: Int(ent.puffsTaken)
            )
            subject.send(ap)
        }
    }

    func loadActivePhase() -> AnyPublisher<ActivePhase, Never> {
        subject.eraseToAnyPublisher()
    }

    func saveActivePhase(_ active: ActivePhase) {
        let req: NSFetchRequest<ActivePhasesEntity> = ActivePhasesEntity.fetchRequest()
        req.fetchLimit = 1
        let ent = (try? viewContext.fetch(req).first) ?? ActivePhasesEntity(context: viewContext)
        ent.phaseIndex = Int16(active.phaseIndex)
        ent.phaseStartDate = active.phaseStartDate
        ent.puffsTaken = Int16(active.puffsTaken)
        try? viewContext.save()
        subject.send(active)
    }
}

class PuffRepositoryCoreData: PuffRepositoryProtocol {
    private let subject = CurrentValueSubject<[PuffEntry], Never>([])

    init() { loadAll() }

    private func loadAll() {
        let req: NSFetchRequest<PuffEntryEntity> = PuffEntryEntity.fetchRequest()
        req.sortDescriptors = [NSSortDescriptor(keyPath: \PuffEntryEntity.timestamp, ascending: true)]
        if let ents = try? viewContext.fetch(req) {
            let puffs = ents.map { ent in
                PuffEntry(
                    id: ent.id ?? UUID(),
                    timestamp: ent.timestamp ?? Date(),
                    duration: ent.duration,
                    phaseIndex: Int(ent.phaseIndex)
                )
            }
            subject.send(puffs)
        }
    }

    func loadPuffs() -> AnyPublisher<[PuffEntry], Never> {
        subject.eraseToAnyPublisher()
    }

    func addPuff(_ puff: PuffEntry) {
        let ent = PuffEntryEntity(context: viewContext)
        ent.id = puff.id
        ent.timestamp = puff.timestamp
        ent.duration = puff.duration
        ent.phaseIndex = Int16(puff.phaseIndex)
        try? viewContext.save()
        var current = subject.value
        current.append(puff)
        subject.send(current)
    }
}

// MARK: - ViewModel (Core Data-backed)

class SessionViewModel: ObservableObject {
    @Published var allPhases: [Phase] = []
    @Published var session: SessionLifetime?
    @Published var active: ActivePhase = ActivePhase(phaseIndex: 0, phaseStartDate: Date(), puffsTaken: 0)
    @Published var puffs: [PuffEntry] = []
    @Published var timeRemaining: TimeInterval = 0
    
    private var cancellables = Set<AnyCancellable>()
    private var timerCancellable: AnyCancellable?
    
    private let phaseRepo: PhaseRepositoryProtocol
    private let sessionRepo: SessionLifetimeRepositoryProtocol
    private let activeRepo: ActivePhaseRepositoryProtocol
    private let puffRepo: PuffRepositoryProtocol
    
    init(
        phaseRepo: PhaseRepositoryProtocol = PhaseRepositoryCoreData(),
        sessionRepo: SessionLifetimeRepositoryProtocol = SessionLifetimeRepositoryCoreData(),
        activeRepo: ActivePhaseRepositoryProtocol = ActivePhaseRepositoryCoreData(),
        puffRepo: PuffRepositoryProtocol = PuffRepositoryCoreData()
    ) {
        self.phaseRepo = phaseRepo
        self.sessionRepo = sessionRepo
        self.activeRepo = activeRepo
        self.puffRepo = puffRepo
        setupBindings()
    }
    
    private func setupBindings() {
        phaseRepo.fetchPhases()
            .sink { [weak self] phases in
                self?.allPhases = phases
                self?.startTimer()
            }
            .store(in: &cancellables)
        
        sessionRepo.loadSession()
            .sink { [weak self] sess in
                self?.session = sess
            }
            .store(in: &cancellables)
        
        activeRepo.loadActivePhase()
            .sink { [weak self] active in
                self?.active = active
                self?.updateTimeRemaining()
            }
            .store(in: &cancellables)
        
        puffRepo.loadPuffs()
            .sink { [weak self] puffs in
                self?.puffs = puffs
            }
            .store(in: &cancellables)
    }
    
    private func startTimer() {
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateTimeRemaining()
            }
    }
    
    private func updateTimeRemaining() {
        guard allPhases.indices.contains(active.phaseIndex) else { return }
        let current = allPhases[active.phaseIndex]
        let elapsed = Date().timeIntervalSince(active.phaseStartDate)
        timeRemaining = max(0, current.duration - elapsed)
    }
}
