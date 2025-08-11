import SwiftUI
import CoreData

struct MainView: View {
    @StateObject private var vm: MainViewModel

    init(context: NSManagedObjectContext) {
        _vm = StateObject(wrappedValue: MainViewModel(context: context))
    }
    
        var color: Color {
            return vm.state == .unlocked ? .green : .mint
            }    //    var color: Gradient = Gradient(colors: [Color.mint.opacity(0.8), Color.teal])
    
           private var darkGreen: Color {
               Color(red: 18/255, green: 24/255, blue: 22/255)
           }
    
           private var darkMint: Color {
               Color(red: 10/255, green: 20/255, blue: 18/255)
           }
    
           private var backgroundColor: Color {
               vm.state == .unlocked
                   ? darkGreen
                   : darkMint
           }

    private var arcColor: Color {
        vm.state == .unlocked ? .green : .mint
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 40) {
                // 🔑 Use the new computed property here:
                Text("Connected: \(vm.username)")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.gray)
                .frame(width: 300, height: 50)
                
                Spacer()
                
                Text("Phase: \(vm.currentPhaseIndex)")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.gray)
                .frame(width: 300, height: 50)
                
                Spacer()

                TimerArc(
                    state:    vm.state,
                    progress: vm.progress,
                    time:     vm.ratioString
                )
                .frame(width: 250, height: 250)
//                .foregroundColor(arcColor)

                DeviceStatusBar(
                    color:    .gray,
                    label:    vm.timeRemainingString,
                    progress: vm.timeProgress
                )
                .frame(height: 20)
                .padding(.horizontal)
                .padding(.bottom, 40)
                Spacer()
            }
        }
    }
}

#if DEBUG
struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        let ctx = PersistenceController.preview.container.viewContext
        MainView(context: ctx)
            .environment(\.managedObjectContext, ctx)
    }
}
#endif


//import SwiftUI
//
//struct MainView: View {
//    @ObservedObject private var trackerData: TrackerDataModel
//    
//    init(trackerData: TrackerDataModel) {
//        self.trackerData = trackerData
//    }
//    
//    var color: Color {
//        return trackerData.progress == 1 ? .green : .mint
//        }    //    var color: Gradient = Gradient(colors: [Color.mint.opacity(0.8), Color.teal])
//
//       private var darkGreen: Color {
//           Color(red: 18/255, green: 24/255, blue: 22/255)
//       }
//       
//       private var darkMint: Color {
//           Color(red: 10/255, green: 20/255, blue: 18/255)
//       }
//
//       private var backgroundColor: Color {
//           trackerData.progress == 1
//               ? darkGreen
//               : darkMint
//       }
//    
//    var body: some View {
//        ZStack {
//            // Background
//            backgroundColor.ignoresSafeArea()
//
//            VStack {
//                Text("Connected: \(trackerData.productName)")
//                    .font(.title3)
//                    .fontWeight(.bold)
//                    .foregroundColor(.gray)
//                    .frame(width: 300, height: 50)
//                
//                Spacer()
//
//                // Lock Timer with Time Display
//                TimerArc(state: trackerData.state, progress: trackerData.progress, time: trackerData.timeString)
//                .frame(width: 250, height: 250)
//                // Horizontal Device Status Bars (Juice & Battery)
//                // HStack(spacing: 35) {
//                //     DeviceStatusBar(color: color, label: "Juice", progress: trackerData.juiceLevel)
//                //     DeviceStatusBar(color: color, label: "Battery", progress: trackerData.batteryLevel)
//                // }
//                .padding(.bottom, 40)
//                // .padding(.horizontal, 30) // Reduce horizontal padding for better spacing
//                // .frame(maxWidth: .infinity, minHeight: 50)
//
//                Spacer()
//                
////                Button(action: {
////                    bluetoothManager.simulateStartCoilTimer()
////                }) {
////                    Text("Simulate puff")
////                        .fontWeight(.bold)
////                        .font(.footnote)
////                        .foregroundColor(Color.white)
////                        .cornerRadius(100)
////                        .padding(.bottom, 40)
////
////                }
//            }
//        }
//    }
//}
//
//#Preview {
//    MainView(trackerData: TrackerDataModel(bluetoothManager: BluetoothManager()))
//}
