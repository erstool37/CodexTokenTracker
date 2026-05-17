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
            HStack(alignment: .firstTextBaseline) {
                Text("Token stats")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                TokenStatsLegend()
            }
            TokenStatsPeriodView(period: stats.weekly, maxTotal: maxTotal)
            TokenStatsPeriodView(period: stats.monthly, maxTotal: maxTotal)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var maxTotal: Int {
        max(stats.weekly.usage.totalTokens, stats.monthly.usage.totalTokens, 1)
    }
}

private struct TokenStatsPeriodView: View {
    let period: TokenUsagePeriodStats
    let maxTotal: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            TokenUsageBarView(usage: period.usage, maxTotal: maxTotal)
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

private struct TokenStatsLegend: View {
    var body: some View {
        HStack(spacing: 8) {
            legendItem("In", .blue)
            legendItem("Out", .teal)
            legendItem("Reason", .orange)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
        }
    }
}

private struct TokenUsageBarView: View {
    let usage: TokenUsageBreakdownDisplay
    let maxTotal: Int

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            let total = max(usage.totalTokens, segmentTotal)
            let filledWidth = availableWidth * CGFloat(min(Double(total) / Double(max(maxTotal, 1)), 1.0))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.14))
                HStack(spacing: 0) {
                    segment(inputTokens, color: .blue, width: filledWidth)
                    segment(outputTokens, color: .teal, width: filledWidth)
                    segment(reasoningTokens, color: .orange, width: filledWidth)
                }
                .frame(width: filledWidth, height: 8, alignment: .leading)
                .clipShape(Capsule())
            }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Token mix")
        .accessibilityValue(
            "Input \(StatusFormatter.compactTokenCount(usage.inputTokens)), output \(StatusFormatter.compactTokenCount(usage.outputTokens)), reasoning \(StatusFormatter.compactTokenCount(usage.reasoningOutputTokens))"
        )
    }

    private var inputTokens: Int {
        max(usage.inputTokens, 0)
    }

    private var outputTokens: Int {
        max(usage.outputTokens - usage.reasoningOutputTokens, 0)
    }

    private var reasoningTokens: Int {
        max(usage.reasoningOutputTokens, 0)
    }

    private var segmentTotal: Int {
        max(inputTokens + outputTokens + reasoningTokens, 1)
    }

    @ViewBuilder
    private func segment(_ value: Int, color: Color, width: CGFloat) -> some View {
        if value > 0 {
            Rectangle()
                .fill(color)
                .frame(width: width * CGFloat(value) / CGFloat(segmentTotal))
        }
    }
}
