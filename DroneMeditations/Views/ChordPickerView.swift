import SwiftUI

struct ChordPickerView: View {
    @EnvironmentObject var vm: DroneViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    keySection
                    octaveSection
                    tuningSection
                    chordSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Chord & Tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Key

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KEY")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(PitchClass.allCases) { pc in
                    Button {
                        vm.setKey(pc)
                    } label: {
                        Text(pc.displayName)
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(vm.currentKey == pc ? Color.white.opacity(0.85) : Color.white.opacity(0.07))
                            )
                            .foregroundStyle(vm.currentKey == pc ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Octave

    private var octaveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OCTAVE")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { vm.setOctave(vm.currentOctave - 1) } label: {
                    Image(systemName: "minus")
                        .frame(width: 40, height: 38)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(vm.currentOctave <= DroneViewModel.octaveRange.lowerBound)

                Text("\(vm.currentOctave)")
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .frame(maxWidth: .infinity)

                Button { vm.setOctave(vm.currentOctave + 1) } label: {
                    Image(systemName: "plus")
                        .frame(width: 40, height: 38)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(vm.currentOctave >= DroneViewModel.octaveRange.upperBound)
            }
        }
    }

    // MARK: - Tuning

    private var tuningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TUNING SYSTEM")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ForEach(TuningSystem.allCases) { t in
                    Button {
                        vm.setTuning(t)
                    } label: {
                        Text(t.displayName)
                            .font(.system(.footnote, design: .rounded).weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(vm.currentTuning == t ? Color.white.opacity(0.85) : Color.white.opacity(0.07))
                            )
                            .foregroundStyle(vm.currentTuning == t ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Chord

    private var chordSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CHORD")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.secondary)
            ForEach(ChordType.Category.allCases, id: \.self) { cat in
                if let chords = ChordType.byCategory[cat] {
                    Text(cat.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                        ForEach(chords) { c in
                            Button {
                                vm.setChord(c)
                            } label: {
                                Text(c.name)
                                    .font(.system(.footnote, design: .rounded).weight(.medium))
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(vm.currentChord == c ? Color.white.opacity(0.85) : Color.white.opacity(0.07))
                                    )
                                    .foregroundStyle(vm.currentChord == c ? .black : .white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
