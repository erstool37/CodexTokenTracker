import CodexTokenTrackerCore
import SwiftUI

// MARK: - Brand colors

extension Color {
    static let codexAccent = Color(red: 30 / 255, green: 136 / 255, blue: 229 / 255)
    static let claudeAccent = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
}

// MARK: - Provider accent environment key

private struct ProviderAccentKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    var providerAccent: Color {
        get { self[ProviderAccentKey.self] }
        set { self[ProviderAccentKey.self] = newValue }
    }
}

// MARK: - Popover root

struct StatusPopoverView: View {
    @ObservedObject var store: StatusStore
    @ObservedObject var claudeStore: StatusStore

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ProviderPaneView(
                    title: "Codex",
                    store: store,
                    loadingMessage: "Waiting for codex app-server.",
                    accent: .codexAccent
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                ProviderPaneView(
                    title: "Claude",
                    store: claudeStore,
                    loadingMessage: "Reading Anthropic usage.",
                    accent: .claudeAccent
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
            footer
        }
        .padding(10)
        .frame(width: 420, height: 400)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                store.refresh()
                claudeStore.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing && claudeStore.isRefreshing)
            .help("Refresh both")

            Button {
                NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!)
            } label: {
                Label("Codex usage", systemImage: "arrow.up.right.square")
                    .foregroundStyle(Color.codexAccent)
            }
            .help("Open Codex usage")

            Button {
                NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
            } label: {
                Label("Claude usage", systemImage: "arrow.up.right.square")
                    .foregroundStyle(Color.claudeAccent)
            }
            .help("Open Claude usage")

            Spacer()
        }
        .labelStyle(.iconOnly)
    }
}

/// One column of the popover. Renders a provider's load state (loading / snapshot / error)
/// using the shared `SnapshotView`. Errors are shown inline so one provider failing never
/// affects the other column.
private struct ProviderPaneView: View {
    let title: String
    @ObservedObject var store: StatusStore
    let loadingMessage: String
    let accent: Color

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)

                switch store.state {
                case .idle, .refreshing:
                    loadingView
                case let .loaded(snapshot):
                    SnapshotView(snapshot: snapshot, stale: store.stale)
                case let .failed(previous, message):
                    if let previous {
                        SnapshotView(snapshot: previous, stale: true)
                    }
                    errorView(message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.providerAccent, accent)
    }

    private var loadingView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Loading \(title)")
                .font(.caption)
            Text(loadingMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorView(_ message: String) -> some View {
        // A rate-limit is a transient, self-healing state — present it calmly (clock, neutral)
        // rather than as a hard "⚠ Unavailable" error so it doesn't read as something broken.
        let isRateLimited = message.localizedCaseInsensitiveContains("rate-limit")
        return VStack(alignment: .leading, spacing: 4) {
            Label(
                isRateLimited ? "Waiting" : "Unavailable",
                systemImage: isRateLimited ? "clock.arrow.circlepath" : "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(isRateLimited ? .secondary : .primary)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SnapshotView: View {
    let snapshot: CodexStatusSnapshot
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let credits = snapshot.credits {
                CreditCardView(credits: credits)
            } else {
                Text("No local usage logs found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.limits.compactMap(\.statusText), id: \.self) { statusText in
                Label(statusText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            freshness
        }
    }

    private var freshness: some View {
        HStack {
            Text("Last refreshed")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(snapshot.refreshedAt, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(stale ? .orange : .secondary)
        }
    }
}

/// Usage priced in the provider's credit unit: period totals, then where the last 7 days went.
private struct CreditCardView: View {
    let credits: CreditUsageStats
    @Environment(\.providerAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(credits.unit == .usd ? "Credits (USD)" : "Credits")
                .font(.subheadline.weight(.semibold))
            ForEach(credits.periods, id: \.label) { period in
                HStack(alignment: .firstTextBaseline) {
                    Text(period.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(credits.unit.format(period.credits))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                .font(.caption)
            }

            if !credits.weeklyByModel.isEmpty {
                Divider()
                Text("7 days by model")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(credits.weeklyByModel.prefix(4), id: \.model) { share in
                    HStack(alignment: .firstTextBaseline) {
                        Text(share.model)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(credits.unit.format(share.credits))
                            .monospacedDigit()
                    }
                    .font(.caption2)
                }
            }

            if credits.unpricedTokens > 0 {
                Text("Unpriced: \(StatusFormatter.compactTokenCount(credits.unpricedTokens)) tokens (\(credits.unpricedModels.joined(separator: ", ")))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(credits.note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
