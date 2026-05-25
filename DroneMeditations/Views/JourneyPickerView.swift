import SwiftUI

/// Modal sheet that lists meditation journeys (both user-composed and
/// curated) and lets the user start/stop, edit, delete, or create.
/// Mirrors the web journey-sheet UI.
struct JourneyPickerView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss

    /// Non-nil when the composer sheet is presented. `editing` carries the
    /// journey being edited (or nil for "new").
    @State private var composerSeed: ComposerSeed?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    Text("A journey auto-advances through multiple presets + drift scenes over a fixed duration. The session timer is set to the journey total; transport fades out at the end.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .padding(.horizontal, 4)

                    // Composer launcher — always at top so it's discoverable.
                    Button {
                        composerSeed = ComposerSeed(editing: nil)
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Create your own journey")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.30), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                        )
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    if !vm.userJourneys.isEmpty {
                        sectionHeader("Your journeys")
                        ForEach(vm.userJourneys) { uj in
                            userJourneyCard(uj)
                        }
                        sectionHeader("Curated journeys")
                            .padding(.top, 6)
                    }

                    ForEach(Journey.all) { journey in
                        journeyCard(journey)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Meditation Journeys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $composerSeed) { seed in
                JourneyComposerView(editing: seed.editing) {
                    composerSeed = nil
                }
                .environmentObject(vm)
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.10 * 10)
                .foregroundStyle(.white.opacity(0.50))
            Spacer()
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func journeyCard(_ j: Journey) -> some View {
        let isActive = vm.activeJourneyId == j.id
        let stagesView = ForEach(Array(j.stages.enumerated()), id: \.offset) { i, stage in
            stageRow(index: i, hint: stage.hint, durationSec: stage.durationSec, isCurrent: isActive && i == vm.journeyStageIndex)
        }
        cardShell(name: j.name,
                  totalSeconds: j.totalSeconds,
                  stageCount: j.stages.count,
                  description: j.description,
                  isActive: isActive,
                  isUser: false,
                  startStop: {
                      if isActive { vm.stopJourney() }
                      else { vm.startJourney(j.id); dismiss() }
                  },
                  onEdit: nil,
                  onDelete: nil) {
            VStack(alignment: .leading, spacing: 4) { stagesView }
        }
    }

    @ViewBuilder
    private func userJourneyCard(_ uj: UserJourney) -> some View {
        let isActive = vm.activeJourneyId == uj.id
        let stagesView = ForEach(Array(uj.stages.enumerated()), id: \.offset) { i, stage in
            stageRow(index: i, hint: stage.hint, durationSec: stage.durationSec, isCurrent: isActive && i == vm.journeyStageIndex)
        }
        cardShell(name: uj.name,
                  totalSeconds: uj.totalSeconds,
                  stageCount: uj.stages.count,
                  description: uj.description.isEmpty ? "Custom journey" : uj.description,
                  isActive: isActive,
                  isUser: true,
                  startStop: {
                      if isActive { vm.stopJourney() }
                      else { vm.startJourney(uj.id); dismiss() }
                  },
                  onEdit: { composerSeed = ComposerSeed(editing: uj) },
                  onDelete: { vm.deleteUserJourney(uj.id) }) {
            VStack(alignment: .leading, spacing: 4) { stagesView }
        }
    }

    @ViewBuilder
    private func cardShell<Content: View>(
        name: String,
        totalSeconds: TimeInterval,
        stageCount: Int,
        description: String,
        isActive: Bool,
        isUser: Bool,
        startStop: @escaping () -> Void,
        onEdit: (() -> Void)?,
        onDelete: (() -> Void)?,
        @ViewBuilder body: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                    Text("\(Int(totalSeconds/60)) min · \(stageCount) stage\(stageCount == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                HStack(spacing: 6) {
                    if let onEdit {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.white.opacity(0.10)))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    if let onDelete {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.white.opacity(0.10)))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(action: startStop) {
                        Text(isActive ? "Stop" : "Start")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(isActive ? Color(red: 0.86, green: 0.31, blue: 0.31) : Color.accentColor))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            body()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? Color(red: 1.0, green: 0.85, blue: 0.55).opacity(0.12) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isActive
                                ? Color(red: 1.0, green: 0.85, blue: 0.55).opacity(0.35)
                                : (isUser ? Color(red: 0.56, green: 0.73, blue: 0.85).opacity(0.45)
                                          : Color.white.opacity(0.08)),
                                lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func stageRow(index: Int, hint: String, durationSec: TimeInterval, isCurrent: Bool) -> some View {
        HStack(spacing: 6) {
            Text(isCurrent ? "▶" : "·")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isCurrent ? Color(red: 1.0, green: 0.85, blue: 0.55) : .white.opacity(0.5))
                .frame(width: 14)
            Text("\(Int(durationSec/60)) min — \(hint)")
                .font(.system(size: 11))
                .foregroundStyle(isCurrent ? .white : .white.opacity(0.6))
        }
    }
}

// Identifiable wrapper so `sheet(item:)` can present the composer for either
// a brand-new journey (editing == nil) or an existing one (editing == uj).
private struct ComposerSeed: Identifiable {
    let id = UUID()
    let editing: UserJourney?
}

// MARK: - Composer

/// Inline composer to build or edit a UserJourney.
private struct JourneyComposerView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss
    let editing: UserJourney?
    let onClose: () -> Void

    @State private var name: String
    @State private var description: String
    @State private var stages: [DraftStage]
    @State private var error: String?

    private let driftSceneIds: [String]

    init(editing: UserJourney?, onClose: @escaping () -> Void) {
        self.editing = editing
        self.onClose = onClose
        let initialStages: [DraftStage]
        if let editing {
            initialStages = editing.stages.map { DraftStage(durationMin: Double($0.durationSec) / 60.0,
                                                            presetName: $0.presetName,
                                                            driftSceneId: $0.driftSceneId) }
        } else {
            let firstPreset = Preset.all.first?.name ?? "Earth Drone"
            initialStages = [DraftStage(durationMin: 5, presetName: firstPreset, driftSceneId: "off")]
        }
        _name = State(initialValue: editing?.name ?? "")
        _description = State(initialValue: editing?.description ?? "")
        _stages = State(initialValue: initialStages)
        // Drift scene ids are owned by the view model; computed here so the
        // dropdown's option list stays in sync if drift scenes change.
        self.driftSceneIds = DroneViewModel.driftScenes.map { $0.id }
    }

    var totalMin: Double {
        stages.reduce(0) { $0 + $1.durationMin }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Journey") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section {
                    ForEach(stages.indices, id: \.self) { idx in
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Preset", selection: $stages[idx].presetName) {
                                ForEach(Preset.all) { p in
                                    Text(p.name).tag(p.name)
                                }
                            }
                            .pickerStyle(.menu)

                            Picker("Drift", selection: $stages[idx].driftSceneId) {
                                ForEach(driftSceneIds, id: \.self) { sid in
                                    Text(sid).tag(sid)
                                }
                            }
                            .pickerStyle(.menu)

                            HStack {
                                Text("Duration")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Stepper(value: $stages[idx].durationMin, in: 0.5...90, step: 0.5) {
                                    Text("\(stages[idx].durationMin, specifier: "%.1f") min")
                                        .monospacedDigit()
                                }
                                .labelsHidden()
                                Text("\(stages[idx].durationMin, specifier: "%.1f") min")
                                    .monospacedDigit()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        // Never delete the last remaining stage.
                        guard stages.count > 1 else { return }
                        stages.remove(atOffsets: offsets)
                    }

                    Button {
                        let firstPreset = Preset.all.first?.name ?? "Earth Drone"
                        stages.append(DraftStage(durationMin: 5, presetName: firstPreset, driftSceneId: "off"))
                    } label: {
                        Label("Add stage", systemImage: "plus")
                    }
                } header: {
                    Text("Stages")
                } footer: {
                    Text("Total: \(String(format: "%.1f", totalMin)) min · \(stages.count) stage\(stages.count == 1 ? "" : "s")")
                }

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            .navigationTitle(editing == nil ? "New Journey" : "Edit Journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onClose(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .bold()
                }
            }
        }
    }

    private func save() {
        let mapped = stages.map { d in
            UserJourney.Stage(
                durationSec: max(30, min(90 * 60, d.durationMin * 60)),
                presetName: d.presetName,
                driftSceneId: d.driftSceneId,
                hint: "\(d.presetName) · \(d.driftSceneId)"
            )
        }
        let ok = vm.saveUserJourney(
            name: name,
            description: description,
            stages: mapped,
            existingId: editing?.id
        )
        if ok {
            onClose()
            dismiss()
        } else {
            error = "Give the journey a name and at least one valid stage."
        }
    }
}

private struct DraftStage: Identifiable, Hashable {
    let id = UUID()
    var durationMin: Double
    var presetName: String
    var driftSceneId: String
}
