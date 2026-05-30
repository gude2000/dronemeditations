import SwiftUI

struct PresetPickerView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingSaveAlert = false
    // v1.1 perf fix: do NOT hold the typed preset name as @State on this
    // view. PresetPickerView's body contains the big ForEach over all
    // bundled + user presets — re-evaluating it on every keystroke
    // produced enough main-thread pressure to make the audio render
    // thread stutter during typing. The name now lives inside
    // SavePresetSheet (its own @State) and is emitted only when the
    // user taps Save.

    // v1.1 cross-device preset sharing.
    @State private var showingImporter = false
    @State private var importBanner: String? = nil
    @State private var importBannerIsError = false
    /// Currently-presented share-sheet payload. Identifiable wrapper
    /// around a temp URL so .sheet(item:) can fire — and so we pack the
    /// preset file lazily (only when the user actually taps Share),
    /// instead of on every PresetPickerView body re-eval.
    @State private var shareItem: ShareItem? = nil

    private struct ShareItem: Identifiable {
        let id: String         // preset id
        let url: URL
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Binaural beats require headphones to take effect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.white.opacity(0.04))

                if !vm.userPresets.isEmpty {
                    Section("Your Presets") {
                        ForEach(vm.userPresets) { p in
                            HStack {
                                Button {
                                    vm.loadUserPreset(id: p.id)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(p.name)
                                            .font(.system(.body, design: .rounded).weight(.medium))
                                            .foregroundStyle(.white)
                                        Text(p.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                // v1.1: Share the preset as a
                                // `.dronepreset` file — AirDrop / Save
                                // to Files / Mail it to your other
                                // device. We pack the file LAZILY on
                                // tap, not on every body re-eval, to
                                // avoid hundreds of JSON encodes per
                                // render of a long preset list.
                                Button {
                                    if let url = vm.exportUserPresetURL(id: p.id) {
                                        shareItem = ShareItem(id: p.id, url: url)
                                    }
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                                Button {
                                    vm.deleteUserPreset(id: p.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 14)
                            }
                            .listRowBackground(
                                vm.activePresetName == p.name
                                    ? Color.white.opacity(0.15)
                                    : Color.white.opacity(0.04)
                            )
                        }
                    }
                }

                ForEach(Preset.Category.allCases, id: \.self) { cat in
                    if let presets = Preset.byCategory[cat] {
                        Section(cat.rawValue) {
                            ForEach(presets) { p in
                                Button {
                                    vm.applyPreset(p)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(p.name)
                                            .font(.system(.body, design: .rounded).weight(.medium))
                                            .foregroundStyle(.white)
                                        if let sub = p.subtitle {
                                            Text(sub)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                    // contentShape makes the whole row a tap
                                    // target — without it, only the text
                                    // glyphs are tappable and the user has to
                                    // tap precisely on a letter.
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                // .buttonStyle(.plain) is REQUIRED here.
                                // Without it, SwiftUI's List wraps the button
                                // in its own row-selection gesture which
                                // swallows the first tap (the user has to tap
                                // twice). The User Presets section already
                                // has this; this section was missing it.
                                .buttonStyle(.plain)
                                .listRowBackground(
                                    vm.activePresetName == p.name
                                        ? Color.white.opacity(0.15)
                                        : Color.white.opacity(0.04)
                                )
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Save Current") {
                        showingSaveAlert = true
                    }
                }
                // v1.1: Import a `.dronepreset` file the user received
                // (AirDrop / Files / iCloud Drive / Mail). Files-app
                // picker handles security-scoped URL bracketing for us.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Use a SwiftUI sheet rather than a system .alert() to avoid
            // an audible "crackle" when the alert appears or dismisses.
            // Alerts with text fields force iOS to swap the audio session
            // (because the system keyboard is its own audio route consumer);
            // SwiftUI sheets stay in our process and don't disturb the
            // session.
            .sheet(isPresented: $showingSaveAlert) {
                // v1.1 perf fix: the name lives in SavePresetSheet's own
                // @State now, not as a Binding from this parent. The
                // typed value is only emitted via the onSave closure,
                // so per-keystroke updates don't re-render the big
                // ForEach over presets above.
                SavePresetSheet { trimmed in
                    vm.saveCurrentAsUserPreset(named: trimmed)
                }
                .presentationDetents([.height(260)])
            }
            // v1.1: Share sheet for `.dronepreset` export. Wrapped via
            // .sheet(item:) so the URL is captured at tap time, not
            // re-built on every body re-eval.
            .sheet(item: $shareItem) { item in
                ShareActivityView(items: [item.url])
            }
            // v1.1: Files-app picker for `.dronepreset` import.
            // allowedContentTypes accepts both our custom UTI (when the
            // file was authored by us) and generic JSON (fallback for
            // files whose UTI wasn't preserved across sharing apps —
            // e.g. some email clients strip type metadata).
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.dronePreset, .json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    if let name = vm.importUserPreset(from: url) {
                        importBanner = "Imported \u{201C}\(name)\u{201D}"
                        importBannerIsError = false
                    } else {
                        importBanner = "Couldn't import that file."
                        importBannerIsError = true
                    }
                case .failure:
                    importBanner = "File picker cancelled."
                    importBannerIsError = true
                }
            }
            // Transient banner for import success / failure (auto-fades
            // after 2.5 s). Overlays on top of the list so the user
            // gets confirmation without an alert interrupting flow.
            .overlay(alignment: .top) {
                if let msg = importBanner {
                    Text(msg)
                        .font(.system(.footnote, design: .rounded).weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(importBannerIsError
                                           ? Color.red.opacity(0.75)
                                           : Color.green.opacity(0.75))
                        )
                        .padding(.top, 8)
                        .transition(.opacity)
                        .task(id: msg) {
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            importBanner = nil
                        }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Share & UTI helpers

/// Tiny UIActivityViewController wrapper so we can present a share
/// sheet from SwiftUI. The standard `ShareLink` API would have
/// captured the URL eagerly at body-evaluation time; this lets us
/// pack the file lazily on tap.
private struct ShareActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

import UniformTypeIdentifiers

extension UTType {
    /// Custom UTI for `.dronepreset` files. Wired up in Info.plist via
    /// UTExportedTypeDeclarations so the system associates incoming
    /// files with this app. Conforms to `public.json` so generic JSON
    /// pickers also accept it as a fallback.
    static var dronePreset: UTType {
        UTType(exportedAs: "com.gude2000.dronemeditations.preset",
               conformingTo: .json)
    }
}

/// Compact modal sheet for naming a new user preset. Replaces the iOS
/// system .alert() (which caused audible crackle from audio-session
/// keyboard handoff). Submits on Save tap or Enter; Cancel closes
/// without saving.
///
/// v1.1 perf fix: the typed name is held as the sheet's OWN @State
/// (not a Binding from the parent picker). Per-keystroke updates
/// re-evaluate only this small sheet's body, never the parent
/// PresetPickerView's big ForEach over presets — which used to
/// re-build every preset row on every character and stutter the
/// audio render thread.
private struct SavePresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    let onSave: (String) -> Void
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Preset name", text: $name)
                        .focused($nameFieldFocused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                } footer: {
                    Text("Saves all 4 oscillator settings, filter, reverb, delay, LFOs, and any loaded samples.")
                }
            }
            .navigationTitle("Save Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                // Auto-focus the field so the user can start typing
                // immediately (matches the old alert's behavior).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    nameFieldFocused = true
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
