//
//  RestartConfirmationView.swift
//  IOTA Watchdog
//
//  The 60-second window shown before any automatic restart, so a stop the user made on purpose
//  is never undone behind their back.
//

import SwiftUI

struct RestartConfirmationView: View {
    @ObservedObject var coordinator: WatchdogCoordinator

    var body: some View {
        let pending = coordinator.pendingConfirmation

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inactiveRed)
                            .background(Circle().fill(Theme.background).frame(width: 14, height: 14))
                            .offset(x: 3, y: 3)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending?.trigger.title ?? "IOTA miner stopped")
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                    Text(countdownText(pending))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryMuted)
                        .monospacedDigit()
                }
                Spacer()
            }

            if let pending {
                Text(pending.trigger.detail)
                    .font(.callout)
                    .foregroundStyle(Theme.primaryText)

                Text(pending.evidence)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.mutedText)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardFill))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder))

                ProgressView(value: progress(pending))
                    .tint(Theme.inactiveRed)
            }

            HStack {
                Button("Cancel") { coordinator.cancelPendingRestart() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restart now") {
                    Task { await coordinator.confirmRestartNow() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(Theme.background)
    }

    private func countdownText(_ pending: WatchdogCoordinator.PendingConfirmation?) -> String {
        guard let pending else { return "Restarting…" }
        let seconds = pending.secondsRemaining
        return "Restarting automatically in \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func progress(_ pending: WatchdogCoordinator.PendingConfirmation) -> Double {
        let total = max(1, coordinator.settings.countdownSeconds)
        return 1 - (Double(pending.secondsRemaining) / Double(total))
    }
}
