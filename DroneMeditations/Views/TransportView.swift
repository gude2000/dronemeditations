import SwiftUI

struct TransportView: View {
    @EnvironmentObject var vm: DroneViewModel
    @ObservedObject var controller: DroneController

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                Spacer()

                Button {
                    if controller.state == .playing {
                        controller.pause()
                    } else {
                        controller.play()
                    }
                } label: {
                    Image(systemName: controller.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .bold))
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Color.white))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)

                Button {
                    controller.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(controller.state == .stopped)

                Spacer()
            }

            HStack(spacing: 18) {
                Text(timeLabel)
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(minWidth: 96, alignment: .leading)

                Spacer()

                Menu {
                    ForEach(DroneController.durationChoices, id: \.self) { d in
                        Button {
                            controller.sessionDuration = d
                        } label: {
                            if d == 0 {
                                Label("Open (no auto-stop)", systemImage: "infinity")
                            } else {
                                Text("\(Int(d / 60)) min")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                        Text(durationLabel)
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var timeLabel: String {
        if controller.sessionDuration > 0 {
            return "\(format(controller.elapsed)) / \(format(controller.sessionDuration))"
        } else {
            return format(controller.elapsed)
        }
    }

    private var durationLabel: String {
        if controller.sessionDuration == 0 { return "Open" }
        return "\(Int(controller.sessionDuration / 60)) min"
    }

    private func format(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
