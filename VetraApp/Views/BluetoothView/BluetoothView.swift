import SwiftUI

struct BluetoothView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    
    var deviceName: String {
            UIDevice.current.name // Returns only 'iPhone' without an entitlement from Apple
        }
    
    init(bluetoothManager: BluetoothManager) {
        self.bluetoothManager = bluetoothManager
    }

    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color.mint.opacity(0.8), Color.teal]),
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if (bluetoothManager.bluetoothState == .poweredOn) {
                // Bluetooth ON: Show Ripple Effect & Scanning UI

                VStack {
                    Spacer()

                    // Centered Ripple Effect
                    RippleEffectView()
                        .frame(width: 200, height: 200)
                        .padding()

                    // All text and button below
                    VStack(spacing: 2) {
                        // User's iPhone with Icon
                        HStack {
                            Image(systemName: deviceName.lowercased()) // iPhone symbol
                                .font(.title3)
                                .foregroundColor(.white)

                            Text(deviceName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        .opacity(0.5)

                        // Discovering Text
                        Text("Discovering product...")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)

                        // "CAN'T FIND PRODUCT" Button
//                        Button(action: {
//                            // Action for when user can't find device
//                        }) {
//                            Text("CAN'T FIND PRODUCT ?")
//                                .fontWeight(.bold)
//                                .padding()
//                                .frame(maxWidth: 240)
//                                .background(Color.white)
//                                .foregroundColor(Color.teal)
//                                .cornerRadius(100)
//                        }
//                        .padding(.top, 20) // Space from text above
                    }
                    .padding(.horizontal, 40) // Maintain horizontal spacing
                    .padding(.vertical, 50)
                    
                    Spacer()
//
//                    HStack(spacing: 20){
//                        Button(action: {
//                            isBluetoothEnabled = false// Action for when user can't find device
//                        }) {
//                            Text("Turn off Bluetooth")
//                                .fontWeight(.bold)
//                                .font(.footnote)
//                                .foregroundColor(Color.white)
//                                .cornerRadius(100)
//                        }
//
//                        Button(action: {
//                            bluetoothManager.isConnected = true
//                        }) {
//                            Text("Simulate Connect")
//                                .fontWeight(.bold)
//                                .font(.footnote)
//                                .foregroundColor(Color.white)
//                                .cornerRadius(100)
//                        }
//                    }
                }
            } else {
               VStack {
                   Spacer()
                   Image("bluetooth")
                       .resizable()
                       .scaledToFit()
                       .frame( maxWidth: 50, maxHeight: 100)
                       .foregroundColor(.white)
                       .opacity(0.5)
                   
                   // All text and button below
                   VStack(spacing: 2) {

                       // Discovering Text
                       Text("Turn on Bluetooth to discover nearby product.")
                           .font(.callout)
                           .frame(maxWidth:.infinity)
                           .fontWeight(.semibold)
                           .foregroundColor(.white)

                       // "CAN'T FIND PRODUCT" Button
                       Button(action: {
                           openBluetoothSettings()
                       }) {
                           Text("TURN ON")
                               .fontWeight(.bold)
                               .padding()
                               .frame(maxWidth: 120)
                               .background(Color.white)
                               .foregroundColor(Color.teal)
                               .cornerRadius(100)
                       }
                       .padding(.top, 20) // Space from text above
                   }
                   .padding(.vertical, 50)
                   
                   Spacer()
               }
            }
        }
    }
    
    private func openBluetoothSettings() {
            guard let url = URL(string: "App-Prefs:root=Bluetooth") else { return }
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            }
        }
}

#Preview {
    BluetoothView(bluetoothManager: BluetoothManager())
}
