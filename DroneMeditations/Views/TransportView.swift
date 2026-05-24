import SwiftUI

struct TransportView: View {
    @EnvironmentObject var vm: DroneViewModel
    @ObservedObject var controller: DroneController

    // iPhone landscape: collapse the 2-row layout into a single horizontal
    // row with smaller transport buttons. Saves ~50px of vertical space.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isCompact: Bool { verticalSizeClass == .compact }

    var body: some View {
        Group {
            if isCompact { compactBody } else { fullBody }
        }
        .padding(.horizontal, isCompact ? 12 : 16)
        .padding(.vertical, isCompact ? 7 : 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var fullBody: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                Spacer()
                playPauseButton(size: 72, iconSize: 32)
                stopButton(size: 56, iconSize: 22)
                Spacer()
            }

            HStack(spacing: 18) {
                Text(timeLabel)
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(minWidth: 96, alignment: .leading)

                Spacer()
                durationMenu
            }
        }
    }

    private var compactBody: some View {
        HStack(spacing: 12) {
            playPauseButton(size: 44, iconSize: 20)
            stopButton(size: 36, iconSize: 14)

            Text(timeLabel)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.white)

            Spacer()

            durationMenu
        }
    }

    private func playPauseButton(size: CGFloat, iconSize: CGFloat) -> some View {
        Button {
            if controller.state == .playing { controller.pause() } else { controller.play() }
        } label: {
            Image(systemName: controller.state == .playing ? "pause.fill" : "play.fill")
                .font(.system(size: iconSize, weight: .bold))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white))
                .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
    }

    private func stopButton(size: CGFloat, iconSize: CGFloat) -> some View {
        Button {
            controller.stop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: iconSize, weight: .bold))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.15)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(controller.state == .stopped)
    }

    private var durationMenu: some View {
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
