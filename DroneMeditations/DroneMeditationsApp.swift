import SwiftUI

@main
struct DroneMeditationsApp: App {
    @StateObject private var viewModel = DroneViewModel()

    /// Drives the first-launch onboarding fullScreenCover. Persisted across
    /// installs in @AppStorage; flips to true once the user finishes or
    /// skips the tour. They can reopen it later via the "?" icon in the
    /// header. We mirror it locally so the cover can present.
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @State private var showingOnboarding: Bool = false

    init() {
        // Make sure Documents/User samples/ exists with a README so the
        // user has somewhere to drop runtime audio files via the Files
        // app. Idempotent — only writes the folder + README if missing,
        // so it's free on every subsequent launch.
        BundledSampleStore.ensureUserSamplesFolderExists()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .fullScreenCover(isPresented: $showingOnboarding) {
                    OnboardingView()
                }
                .onAppear {
                    if !hasSeenOnboarding { showingOnboarding = true }
                }
                // Listen for a manual re-open from the help button.
                .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
                    showingOnboarding = true
                }
        }
    }
}

extension Notification.Name {
    /// Posted by the "?" help button in the header to re-show the tour on
    /// demand for returning users.
    static let showOnboarding = Notification.Name("dronemeditations.showOnboarding")
}
