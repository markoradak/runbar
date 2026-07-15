import SwiftUI

struct MenuBarStatusLabel: View {
    let state: MenuBarIconState

    var body: some View {
        HStack(spacing: 4) {
            icon
            if case let .running(count) = state {
                Text("\(count)")
                    .monospacedDigit()
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .accessibilityLabel(state.accessibilityLabel)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .running:
            Image(systemName: state.systemImage)
                .symbolRenderingMode(.monochrome)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating)
        case .idle:
            Image(systemName: state.systemImage)
                .imageScale(.small)
                .opacity(0.42)
        case .recentFailure:
            Image(systemName: state.systemImage)
                .symbolRenderingMode(.monochrome)
        case .degraded:
            Image(systemName: state.systemImage)
                .symbolRenderingMode(.monochrome)
        case .authenticationRequired:
            Image(systemName: state.systemImage)
                .symbolRenderingMode(.monochrome)
                .opacity(0.65)
        }
    }
}
