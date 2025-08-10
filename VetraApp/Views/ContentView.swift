// ContentView.swift
import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var bluetoothManager: BluetoothManager
    @StateObject private var mainVM = MainViewModel()
    @StateObject private var syncBridge: SyncBridge

    init(bluetoothManager: BluetoothManager = BluetoothManager()) {
        let bm = bluetoothManager
        _bluetoothManager = StateObject(wrappedValue: bm)
        _syncBridge = StateObject(wrappedValue: SyncBridge(bluetoothManager: bm))
    }

    var body: some View {
        ZStack {
            if bluetoothManager.isConnected {
                MainView()
                    .environmentObject(mainVM)
                    .transition(.slide)
            } else {
                BluetoothView(bluetoothManager: bluetoothManager)
                    .transition(.slide)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: bluetoothManager.isConnected)
    }
}

#Preview {
    ContentView()
}
