import SwiftUI
import Combine

enum TimerState {
    case locked
    case unlocked
}

class TrackerDataModel: ObservableObject {
    // These properties are updated from BluetoothManager
    @Published var persistentDuration: CGFloat = 0   // in ms
    @Published var persistentElapsed: CGFloat = 0    // in ms
    @Published var coilDuration: CGFloat = 0         // in ms
    @Published var coilRemaining: CGFloat = 0        // in ms
    
    // Derived properties for UI:
    @Published var state: TimerState = .locked
    @Published var progress: CGFloat = 0
    var productName: String = "Vetra"

    private var cancellables: Set<AnyCancellable> = []
    
    init(bluetoothManager: BluetoothManager) {
        // Subscribe to changes from BluetoothManager.
        bluetoothManager.$persistentDuation
            .sink { [weak self] newValue in
                self?.persistentDuration = newValue
                self?.updateStateAndProgress()
            }
            .store(in: &cancellables)
        
        bluetoothManager.$persistentElapsed
            .sink { [weak self] newValue in
                self?.persistentElapsed = newValue
                self?.updateStateAndProgress()
            }
            .store(in: &cancellables)
        
        bluetoothManager.$coilDuration
            .sink { [weak self] newValue in
                self?.coilDuration = newValue
                self?.updateStateAndProgress()
            }
            .store(in: &cancellables)
        
        bluetoothManager.$coilRemaining
            .sink { [weak self] newValue in
                self?.coilRemaining = newValue
                self?.updateStateAndProgress()
            }
            .store(in: &cancellables)
    }
    
    private func updateStateAndProgress() {
        // Determine state:
        if persistentElapsed < persistentDuration {
            state = .locked
            progress = persistentElapsed / persistentDuration
        } else {
            state = .unlocked
            progress = coilRemaining / coilDuration
        }
    }
    
    // Computed property for the formatted remaining time.
        var timeString: String {
            let remaining: CGFloat
            if state == .locked {
                remaining = persistentDuration - persistentElapsed
            } else {
                remaining = coilRemaining
            }
            let totalSeconds = Int(remaining / 1000)
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            let seconds = totalSeconds % 60
            
            if hours > 0 {
                return String(format: "%dh %dm", hours, minutes)
            } else if minutes > 0 {
                return String(format: "%dm %ds", minutes, seconds)
            } else {
                return String(format: "%ds", seconds)
            }
        }
}
