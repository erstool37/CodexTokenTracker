import CodexTokenTrackerCore
import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var store: StatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 500)
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.monochrome)
            VStack(alignment: .leading, spacing: 2) {
                Text("CodexTokenTracker")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var headerSubtitle: String {
        if store.stale {
            return "Stale"
        }
        if store.isRefreshing {
            return "Refreshing"
        }
        if store.currentSnapshot != nil {
            return "Current"
        }
        return "Unavailable"
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .refreshing:
            loadingView
        case let .loaded(snapshot):
            SnapshotView(snapshot: snapshot, stale: store.stale)
        case let .failed(previous, message):
            if let previous {
                SnapshotView(snapshot: previous, stale: true)
                errorView(message)
            } else {
                errorView(message)
            }
        }
    }

    private var loadingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Loading account status")
                .font(.subheadline)
            Text("Waiting for codex app-server.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Status unavailable", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)

            Button {
                NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!)
            } label: {
                Label("Usage", systemImage: "arrow.up.right.square")
            }

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
        }
        .labelStyle(.iconOnly)
        .help("Refresh, open Codex usage, or quit")
    }
}

private struct SnapshotView: View {
    let snapshot: CodexStatusSnapshot
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            accountSection
            if snapshot.limits.isEmpty {
                Text("No rate-limit data returned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.limits) { bucket in
                    LimitBucketView(bucket: bucket)
                }
            }
            if let tokenStats = snapshot.tokenStats {
                TokenStatsView(stats: tokenStats)
            }
            freshness
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.account.title)
                .font(.subheadline.weight(.semibold))
                .textSelection(.enabled)
            Text(snapshot.account.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LimitWindowView: View {
    let window: LimitWindowDisplay

    var body: some View {
        if window.showsNumericUsage {
            VStack(spacing: 4) {
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

private struct TokenStatsView: View {
    let stats: TokenUsageStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Token stats")
                .font(.subheadline.weight(.semibold))
            TokenStatsPeriodView(period: stats.weekly)
            TokenStatsPeriodView(period: stats.monthly)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TokenStatsPeriodView: View {
    let period: TokenUsagePeriodStats

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(period.label)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(StatusFormatter.compactTokenCount(period.usage.totalTokens))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            HStack(spacing: 10) {
                stat("In", period.usage.inputTokens)
                stat("Out", period.usage.outputTokens)
                stat("Reason", period.usage.reasoningOutputTokens)
                Spacer(minLength: 0)
                Text("\(period.sessionCount) sessions")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
        }
        .font(.caption)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(StatusFormatter.compactTokenCount(value))
                .monospacedDigit()
        }
    }
}
