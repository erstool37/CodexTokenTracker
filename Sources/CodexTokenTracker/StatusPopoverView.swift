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
                CreditBucketView(
                    credits: credits,
                    statusTexts: snapshot.limits.compactMap(\.statusText)
                )
                CreditUsageCardView(credits: credits)
            } else {
                Text("No local usage logs found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

/// Where the last 7 days of credits went, one bar per model (bar = share of the week).
private struct CreditBucketView: View {
    let credits: CreditUsageStats
    let statusTexts: [String]
    @Environment(\.providerAccent) private var accent

    private var weekTotal: Double {
        credits.weeklyByModel.reduce(0) { $0 + $1.credits }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("7-day credits")
                .font(.subheadline.weight(.semibold))
            if credits.weeklyByModel.isEmpty {
                Text("No priced usage in the last 7 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(credits.weeklyByModel.prefix(4), id: \.model) { share in
                CreditShareView(
                    share: share,
                    unit: credits.unit,
                    fraction: weekTotal > 0 ? share.credits / weekTotal : 0
                )
            }
            if credits.unpricedTokens > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text("Unpriced")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(StatusFormatter.compactTokenCount(credits.unpricedTokens)) tokens")
                        .monospacedDigit()
                        .help(credits.unpricedModels.joined(separator: ", "))
                }
                .font(.caption)
            }
            ForEach(statusTexts, id: \.self) { statusText in
                HStack(alignment: .firstTextBaseline) {
                    Text("Status")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(statusText)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
        }
        .padding(8)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A linear usage bar drawn from capsules so its fill color is always honored.
/// The system `ProgressView(.linear)` ignores `.tint` on macOS and falls back to
/// the system accent (blue), which made the Claude pane's bars render blue.
private struct UsageBar: View {
    /// Filled fraction, 0...1.
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(color)
                    .frame(width: min(max(fraction, 0), 1) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

private struct CreditShareView: View {
    let share: CreditModelShare
    let unit: CreditUnit
    let fraction: Double
    @Environment(\.providerAccent) private var accent

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(share.model)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(unit.format(share.credits))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            UsageBar(fraction: fraction, color: accent)
                .accessibilityLabel(share.model)
                .accessibilityValue("\(Int((fraction * 100).rounded())) percent of 7-day credits")
            HStack {
                Spacer()
                Text("\(Int((fraction * 100).rounded()))% of week")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
    }
}

private struct CreditUsageCardView: View {
    let credits: CreditUsageStats
    @Environment(\.providerAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Usage")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
            ForEach(credits.periods, id: \.label) { period in
                CompactValueRow(label: period.label, value: credits.unit.format(period.credits))
            }
            Text(credits.note)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(5)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CompactValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .font(.caption2)
    }
}
