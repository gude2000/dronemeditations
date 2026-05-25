import SwiftUI

/// Modal sheet that lists the available meditation journeys and lets the
/// user start/stop them. Mirrors the web journey-sheet UI.
struct JourneyPickerView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    Text("A journey auto-advances through multiple presets + drift scenes over a fixed duration. The session timer is set to the journey total; transport fades out at the end.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .padding(.horizontal, 4)

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
        }
    }

    @ViewBuilder
    private func journeyCard(_ j: Journey) -> some View {
        let isActive = vm.activeJourneyId == j.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(j.name)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                    Text("\(Int(j.totalSeconds/60)) min · \(j.stages.count) stages")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Button {
                    if isActive {
                        vm.stopJourney()
                    } else {
                        vm.startJourney(j.id)
                        dismiss()
                    }
                } label: {
                    Text(isActive ? "Stop" : "Start")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(isActive ? Color(red: 0.86, green: 0.31, blue: 0.31) : Color.accentColor))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            Text(j.description)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(j.stages.enumerated()), id: \.offset) { i, stage in
                    let isCurrent = isActive && i == vm.journeyStageIndex
                    HStack(spacing: 6) {
                        Text(isCurrent ? "▶" : "·")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isCurrent ? Color(red: 1.0, green: 0.85, blue: 0.55) : .white.opacity(0.5))
                            .frame(width: 14)
                        Text("\(Int(stage.durationSec/60)) min — \(stage.hint)")
                            .font(.system(size: 11))
                            .foregroundStyle(isCurrent ? .white : .white.opacity(0.6))
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? Color(red: 1.0, green: 0.85, blue: 0.55).opacity(0.12) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isActive ? Color(red: 1.0, green: 0.85, blue: 0.55).opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}
