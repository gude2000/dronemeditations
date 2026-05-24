import SwiftUI

@main
struct DroneMeditationsApp: App {
    @StateObject private var viewModel = DroneViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
