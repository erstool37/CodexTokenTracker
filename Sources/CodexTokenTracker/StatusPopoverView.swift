import CodexTokenTrackerCore
import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var store: StatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
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
            Text("Loading Codex status")
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
        }
        .labelStyle(.iconOnly)
        .help("Refresh or open Codex usage")
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
            if let tokenStats = snapshot.tokenStats {
                TokenStatsView(stats: tokenStats)
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
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LimitWindowView: View {
    let window: LimitWindowDisplay

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
            TokenStatsPeriodView(period: stats.today)
            TokenStatsPeriodView(period: stats.weekly)
            TokenStatsPeriodView(period: stats.monthly)
            MonthlyHeatmapView(days: stats.monthlyHeatmap)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TokenStatsPeriodView: View {
    let period: TokenUsagePeriodStats

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(period.label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(StatusFormatter.compactTokenCount(period.usage.totalTokens))
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct MonthlyHeatmapView: View {
    let days: [TokenUsageHeatmapDay]

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 8, maximum: 14), spacing: 4),
        count: 7
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("28-day heatmap")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("peak \(StatusFormatter.compactTokenCount(maxDailyTokens))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: day.usage.totalTokens))
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityLabel("Day \(day.label)")
                        .accessibilityValue(StatusFormatter.compactTokenCount(day.usage.totalTokens))
                }
            }
        }
        .padding(.top, 2)
    }

    private var maxDailyTokens: Int {
        max(days.map { $0.usage.totalTokens }.max() ?? 0, 1)
    }

    private func color(for tokens: Int) -> Color {
        guard tokens > 0 else {
            return Color.secondary.opacity(0.16)
        }
        let ratio = min(max(Double(tokens) / Double(maxDailyTokens), 0.0), 1.0)
        return Color.blue.opacity(0.28 + (0.72 * ratio))
    }
}
