import SwiftUI

struct MenuBarStatusLabel: View {
    let state: MenuBarIconState

    var body: some View {
        HStack(spacing: 3) {
            icon
            if case let .running(count) = state {
                Text("\(count)")
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(state.accessibilityLabel)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .running:
            Image(systemName: state.systemImage)
                .symbolEffect(.pulse, options: .repeating)
        case .idle:
            Image(systemName: state.systemImage)
                .opacity(0.45)
        case .recentFailure:
            Image(systemName: state.systemImage)
                .foregroundStyle(.red)
        case .degraded:
            Image(systemName: state.systemImage)
                .foregroundStyle(.orange)
        case .authenticationRequired:
            Image(systemName: state.systemImage)
                .foregroundStyle(.secondary)
        }
    }
}
