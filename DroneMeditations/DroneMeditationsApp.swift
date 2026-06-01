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
                // Alert behavior: simple "Imported '<name>'" on
                // success (everything the user needs — confirmation +
                // preset name). Failures keep the verbose URL + JSON
                // dump so we can diagnose on physical devices without
                // attaching a debugger.
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

                    // Failure path — gather diagnostic detail. Same
                    // shape as before so we can keep debugging
                    // round-trips on physical devices.
                    let basics = """
                    URL fired:
                    • lastPath: \(url.lastPathComponent)
                    • ext: \(url.pathExtension.isEmpty ? "(none)" : url.pathExtension)
                    • scheme: \(url.scheme ?? "(none)")
                    • isFileURL: \(url.isFileURL)
                    """
                    let sizeLine: String
                    var jsonHead: String = ""
                    if let data = try? Data(contentsOf: url) {
                        sizeLine = "• readable: yes (\(data.count) bytes)"
                        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            let keys = obj.keys.sorted().joined(separator: ", ")
                            jsonHead = "\n• top-level keys: [\(keys)]"
                            if let v = obj["version"] {
                                jsonHead += "\n• version: \(v)"
                            }
                            if let p = obj["preset"] as? [String: Any] {
                                let pk = p.keys.sorted().prefix(8).joined(separator: ", ")
                                jsonHead += "\n• preset keys (first 8): [\(pk)…]"
                            }
                            if let s = obj["samples"] as? [Any] {
                                jsonHead += "\n• samples count: \(s.count)"
                            }
                        } else {
                            jsonHead = "\n• JSON parse: NOT a top-level object"
                        }
                    } else {
                        sizeLine = "• readable: NO (Data(contentsOf:) failed)"
                    }
                    // Re-try at this layer to capture the specific
                    // ImportError (importUserPreset swallows it).
                    var errLine = "IMPORT FAILED (unknown — importer returned nil)"
                    do {
                        _ = try UserPresetSharing.importPreset(from: url)
                    } catch let e as UserPresetSharing.ImportError {
                        errLine = "IMPORT FAILED: \(e.errorDescription ?? "ImportError")"
                    } catch {
                        errLine = "IMPORT FAILED: \(error.localizedDescription)"
                    }
                    importDiagnostic = "\(basics)\n\(sizeLine)\(jsonHead)\n\n\(errLine)"
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
