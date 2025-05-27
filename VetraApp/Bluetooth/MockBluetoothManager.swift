import SwiftUI
import Combine

class MockBluetoothManager: ObservableObject {
    // Published properties (in milliseconds)
    @Published var isConnected: Bool = false
    @Published var persistentTotal: CGFloat = 180_000    // 180 seconds in ms
    @Published var persistentElapsed: CGFloat = 0       // in ms
    @Published var coilTotal: CGFloat = 10_000          // 60 seconds in ms
    @Published var coilElapsed: CGFloat = 0        // in ms

    // Cancellables for the countdown timers
    private var persistentTimerCancellable: AnyCancellable?
    private var coilTimerCancellable: AnyCancellable?
    
    // Simulate a Bluetooth connect event
    public func simulateConnect() {
        isConnected = true
        // Reset persistent timer and start counting
        persistentElapsed = 0
        startPersistentCountdown()
    }
    
    // Start the persistent timer countdown
    private func startPersistentCountdown() {
        persistentTimerCancellable?.cancel()
        persistentTimerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Increase by 1000 ms every 1 second
                if self.persistentElapsed < self.persistentTotal {
                    self.persistentElapsed += 1000
                } else {
                    self.persistentTimerCancellable?.cancel()
                }
            }
    }
    
    // Simulate starting the coil timer.
    // When the coil timer starts, the persistent timer is considered ended.
    public func simulateStartCoilTimer() {
        // Stop the persistent timer countdown
        if persistentTotal == persistentElapsed {
            persistentTimerCancellable?.cancel()
            // Set persistentElapsed to total to simulate that the persistent timer has finished
            persistentElapsed = persistentTotal
            // Reset and start the coil countdown
            coilElapsed = 0
            startCoilCountdown()
        }
    }
    
    // Start the coil timer countdown
    private func startCoilCountdown() {
        coilTimerCancellable?.cancel()
        coilTimerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Increase by 1000 ms every 1 seconds
                if self.coilElapsed < self.coilTotal {
                    self.coilElapsed += 1000
                } else {
                    self.coilTimerCancellable?.cancel()
                    // When coil timer ends, reset the persistent timer and restart its countdown.
                    coilElapsed = 0
                    self.resetPersistentTimer()
                    self.startPersistentCountdown()
                }
            }
    }
    
    // Resets the persistent timer
    private func resetPersistentTimer() {
        persistentElapsed = 0
    }
}
