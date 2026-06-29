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
        VStack(alignment: .leading, spacing: 4) {
            Label("Unavailable", systemImage: "exclamationmark.triangle")
                .font(.caption)
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
            if snapshot.limits.isEmpty {
                Text("No rate-limit data returned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.limits) { bucket in
                    LimitBucketView(bucket: bucket)
                }
            }
            if snapshot.onlineTokenStats != nil || snapshot.onlineTokenStatsError != nil || snapshot.tokenStats != nil {
                UsageStatsView(
                    onlineTokenStats: snapshot.onlineTokenStats,
                    onlineUnavailable: snapshot.onlineTokenStatsError != nil,
                    localTokenStats: snapshot.tokenStats
                )
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

private struct LimitBucketView: View {
    let bucket: LimitBucketDisplay
    @Environment(\.providerAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bucket.label)
                .font(.subheadline.weight(.semibold))
            ForEach(bucket.windows) { window in
                LimitWindowView(window: window)
            }
            if let creditsText = bucket.creditsText {
                HStack {
                    Text("Credits")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(creditsText)
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
            if let statusText = bucket.statusText {
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

private struct LimitWindowView: View {
    let window: LimitWindowDisplay
    @Environment(\.providerAccent) private var accent

    var body: some View {
        if window.showsNumericUsage {
            VStack(spacing: 3) {
                HStack {
                    Text(window.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(window.percentLeft)% left")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                ProgressView(value: Double(window.percentLeft), total: 100)
                    .progressViewStyle(.linear)
                    .tint(window.warningLevel == .normal ? accent : window.warningLevel.progressColor)
                    .accessibilityLabel(window.label)
                    .accessibilityValue("\(window.percentLeft) percent left")
                if let resetsAtText = window.resetsAtText {
                    HStack {
                        Spacer()
                        Text("resets \(resetsAtText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(window.warningLevel.textColor)
        } else {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(iconColor)
                    .accessibilityLabel(window.label)
                Text(window.label)
                    .foregroundStyle(.secondary)
                Spacer()
                if let resetsAtText = window.resetsAtText {
                    Text("resets \(resetsAtText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.caption)
        }
    }

    private var iconName: String {
        switch window.percentLeft {
        case 50...100:
            return "checkmark.circle"
        case 1..<50:
            return "exclamationmark.triangle"
        default:
            return "xmark.circle"
        }
    }

    private var iconColor: Color {
        switch window.percentLeft {
        case 50...100:
            return .secondary
        case 1..<50:
            return .orange
        default:
            return .red
        }
    }
}

private extension LimitWarningLevel {
    var progressColor: Color {
        switch self {
        case .normal:
            return .accentColor
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }

    var textColor: Color {
        switch self {
        case .normal:
            return .primary
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}

private struct UsageStatsView: View {
    let onlineTokenStats: TokenUsageStats?
    let onlineUnavailable: Bool
    let localTokenStats: TokenUsageStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let onlineTokenStats {
                UsageStatsCardView(title: "Usage", stats: onlineTokenStats)
            } else {
                if onlineUnavailable {
                    ExactUsageUnavailableView()
                }
                if let localTokenStats {
                    UsageStatsCardView(title: "Estimated device", stats: localTokenStats)
                }
            }
        }
    }
}

private struct ExactUsageUnavailableView: View {
    @Environment(\.providerAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Usage")
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .firstTextBaseline) {
                Text("Status")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Exact usage unavailable")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(5)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct UsageStatsCardView: View {
    let title: String
    let stats: TokenUsageStats
    @Environment(\.providerAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
            ForEach(stats.periods, id: \.label) { period in
                CompactTokenRow(label: period.label, tokens: period.usage.totalTokens)
            }
            if let note = stats.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(5)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CompactTokenRow: View {
    let label: String
    let tokens: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(StatusFormatter.compactTokenCount(tokens))
                .fontWeight(.semibold)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .font(.caption2)
    }
}
