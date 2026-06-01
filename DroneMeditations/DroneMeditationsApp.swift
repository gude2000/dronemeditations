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
                // v1.1: tap-to-open .dronepreset files from Files /
                // Mail / AirDrop / Messages.
                //
                // v1 fix: dropped the strict `.dronepreset` extension
                // check. When iOS matches the file via our Alternate
                // public.json UTI handler (AirDrop / iMessage from
                // Macs that don't know our custom UTI), the URL it
                // hands us can have a `.json` extension or no
                // extension at all — and the strict guard silently
                // rejected those. Instead we let
                // UserPresetSharing.importPreset try to decode any
                // URL: valid envelopes succeed, anything else throws
                // and bounces out without side effects. Same safety,
                // works for every transport.
                .onOpenURL { url in
                    if let name = viewModel.importUserPreset(from: url) {
                        // Surface a transient confirmation so the user
                        // SEES the import landed. Previously this was
                        // print-only; users opening from AirDrop /
                        // iMessage couldn't tell the import had
                        // succeeded without scrolling to the preset
                        // list.
                        NotificationCenter.default.post(
                            name: .presetImportLanded,
                            object: nil,
                            userInfo: ["name": name]
                        )
                        #if DEBUG
                        print("[preset import via onOpenURL] \(name)")
                        #endif
                    }
                }
        }
    }
}

extension Notification.Name {
    /// Posted by the "?" help button in the header to re-show the tour on
    /// demand for returning users.
    static let showOnboarding = Notification.Name("dronemeditations.showOnboarding")
    /// v1: posted from .onOpenURL when an incoming .dronepreset (or
    /// public.json that decoded as a preset envelope) was imported.
    /// userInfo carries "name" = the preset's display name. Any view
    /// can observe this to surface a confirmation banner.
    static let presetImportLanded = Notification.Name("dronemeditations.presetImportLanded")
}
