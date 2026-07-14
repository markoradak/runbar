import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Runbar")
                    .font(.headline)
                Spacer()
                connectionBadge
            }

            Divider()

            if let login = model.authenticatedLogin {
                Label("Connected as @\(login)", systemImage: "checkmark.circle.fill")
                    .accessibilityIdentifier("menu-authenticated-github-login")
                Text("Repository discovery starts in M1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Add a fine-grained GitHub token in Settings to begin.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                SettingsLink {
                    Label("Settings", systemImage: "gear")
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 340)
        .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch model.state {
        case .authenticated:
            Label("Connected", systemImage: "circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .loading, .validating:
            ProgressView()
                .controlSize(.small)
        case .signedOut, .failed:
            Label("Setup required", systemImage: "circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
