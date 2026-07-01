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

    /// v1 import diagnostic. Set from .onOpenURL — surfaces a system
    /// alert showing what the URL looked like, whether the importer
    /// was reached, and the success/error result. Lets us diagnose
    /// AirDrop / iMessage / Files / Mail tap-to-open flows on
    /// physical devices without attaching a debugger.
    @State private var importDiagnostic: String? = nil

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
                //
                // Alert behavior: simple "Imported '<name>'" on success,
                // and a clean "Couldn't import …" reason on failure — no
                // raw URL / JSON dump in front of the user.
                .onOpenURL { url in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                    if let name = viewModel.importUserPreset(from: url) {
                        // Success path — short, friendly, one line.
                        importDiagnostic = "Imported \"\(name)\""
                        NotificationCenter.default.post(
                            name: Notification.Name("dronemeditations.presetImportLanded"),
                            object: nil,
                            userInfo: ["name": name]
                        )
                        return
                    }

                    // Failure path — a clean, user-facing message. We still
                    // ask the importer for the underlying reason so a
                    // version mismatch says something useful, but we no
                    // longer show the raw URL / JSON / decode internals.
                    var reason = "This file couldn't be read as a Drone Meditations preset."
                    do {
                        _ = try UserPresetSharing.importPreset(from: url)
                    } catch let e as UserPresetSharing.ImportError {
                        switch e {
                        case .unsupportedVersion:
                            reason = e.errorDescription ?? reason
                        case .readFailed:
                            reason = "The file couldn't be opened. Try sharing it again."
                        case .decodeFailed, .decodeFailedDetail:
                            reason = "The file appears to be damaged, or was made with a newer version of the app."
                        }
                    } catch {
                        reason = "Something went wrong reading the file."
                    }
                    importDiagnostic = "Couldn't import \"\(url.lastPathComponent)\".\n\n\(reason)"
                }
                .alert(
                    "Preset Import",
                    isPresented: Binding(
                        get: { importDiagnostic != nil },
                        set: { if !$0 { importDiagnostic = nil } }
                    ),
                    presenting: importDiagnostic
                ) { _ in
                    Button("OK", role: .cancel) { importDiagnostic = nil }
                } message: { msg in
                    Text(msg)
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
