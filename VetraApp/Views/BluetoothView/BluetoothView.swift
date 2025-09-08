//
//  BluetoothView.swift
//  VetraApp
//
//  Discovery/Connect screen. Shows a scanning ripple until a device is
//  discovered. When discovered, stops the ripple and presents a clear
//  "Tap to Connect" affordance. Falls back to system settings if BT off.
//

import SwiftUI

// MARK: - BluetoothView

struct BluetoothView: View {

    @ObservedObject var bluetoothManager: BluetoothManager

    // MARK: Derived UI State

    /// Show ripple only when Bluetooth is ON, not connected, and no device is currently discovered.
    private var rippleActive: Bool {
        bluetoothManager.bluetoothState == .poweredOn &&
        !bluetoothManager.isConnected &&
        bluetoothManager.discoveredPeripheralName == nil
    }

    /// Reserve space below ripple so it doesn’t shift when content changes.
    private let statusAreaHeight: CGFloat = 160

    private var deviceOwnerName: String {
        UIDevice.current.name
    }

    // MARK: Init

    init(bluetoothManager: BluetoothManager) {
        self.bluetoothManager = bluetoothManager
    }

    // MARK: Body

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color.mint.opacity(0.8), Color.teal]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if bluetoothManager.bluetoothState == .poweredOn {
                poweredOnView
            } else {
                poweredOffView
            }
        }
    }

    // MARK: Subviews

    private var poweredOnView: some View {
        VStack(spacing: 0) {
            Spacer()

            // Ripple is anchored here, unaffected by status content
            RippleEffectView(isActive: rippleActive)
                .frame(width: 200, height: 200)
            
            Spacer()

            // Fixed-height area for dynamic status & buttons
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "iphone")
                        .font(.title3)
                        .foregroundColor(.white)

                    Text(deviceOwnerName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
                .opacity(0.5)

                if let name = bluetoothManager.discoveredPeripheralName,
                   !bluetoothManager.isConnected {
                    Text("Discovered \(name)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    Button(action: { bluetoothManager.connectDiscovered() }) {
                        Text("Tap to Connect")
                            .font(.headline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.white)
                            .foregroundColor(.teal)
                            .cornerRadius(20)
                            .shadow(radius: 6)
                    }
                    .accessibilityLabel("Connect to \(name)")
                    .padding(.top, 8)
                } else {
                    Text("Discovering product…")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)
            .frame(maxWidth: .infinity,
                   maxHeight: statusAreaHeight,
                   alignment: .top)

            Spacer()
        }
    }

    private var poweredOffView: some View {
        VStack {
            Spacer()

            Image("bluetooth")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 50, maxHeight: 100)
                .foregroundColor(.white)
                .opacity(0.5)

            VStack(spacing: 12) {
                Text("Turn on Bluetooth to discover nearby product.")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Button(action: openBluetoothSettings) {
                    Text("TURN ON")
                        .fontWeight(.bold)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.white)
                        .foregroundColor(.teal)
                        .cornerRadius(100)
                }
                .padding(.top, 8)
            }
            .padding(.vertical, 50)

            Spacer()
        }
    }

    // MARK: Actions

    /// Attempts to open Bluetooth settings. Falls back to app settings if needed.
    private func openBluetoothSettings() {
        if let url = URL(string: "App-Prefs:root=Bluetooth"),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            return
        }
        if let appSettings = URL(string: UIApplication.openSettingsURLString),
           UIApplication.shared.canOpenURL(appSettings) {
            UIApplication.shared.open(appSettings)
        }
    }
}

// MARK: - Preview

#Preview {
    BluetoothView(bluetoothManager: BluetoothManager())
}
