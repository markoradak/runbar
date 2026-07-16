import AppKit
import SwiftUI

struct MenuBarStatusLabel: View {
    let state: MenuBarIconState

    var body: some View {
        icon
            .font(.system(size: 13, weight: .semibold))
            .accessibilityLabel(state.accessibilityLabel)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .running:
            MenuBarDotLoader(isRunning: true)
        case .idle:
            MenuBarDotLoader(isRunning: false)
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

struct MenuBarDotLoader: View {
    let isRunning: Bool

    var body: some View {
        HStack(spacing: MenuBarActivityIndicatorStyle.columnSpacing) {
            ForEach(0 ..< 2, id: \.self) { _ in
                VStack(spacing: MenuBarActivityIndicatorStyle.rowSpacing) {
                    ForEach(0 ..< 3, id: \.self) { _ in
                        Circle()
                            .frame(
                                width: MenuBarActivityIndicatorStyle.dotDiameter,
                                height: MenuBarActivityIndicatorStyle.dotDiameter
                            )
                    }
                }
            }
        }
        .opacity(isRunning ? 1 : MenuBarActivityIndicatorStyle.idleOpacity)
        .frame(
            width: MenuBarActivityIndicatorStyle.width,
            height: MenuBarActivityIndicatorStyle.height
        )
    }
}
