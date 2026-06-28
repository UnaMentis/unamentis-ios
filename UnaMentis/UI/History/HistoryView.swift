// UnaMentis - History View
// Session history with comprehensive observability
//
// Part of UI/UX (TDD Section 10)

import SwiftUI
import CoreData
import Logging
#if os(iOS)
import UIKit
#endif

// MARK: - History View

/// Session history view showing past conversations
public struct HistoryView: View {
    @StateObject private var viewModel = HistoryViewModel()
    @State private var showingHistoryHelp = false

    private static let logger = Logger(label: "com.unamentis.ui.history.view")

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if viewModel.sessions.isEmpty {
                    EmptyHistoryView()
                } else {
                    SessionListView(sessions: viewModel.sessions) {
                        await viewModel.refresh()
                    }
                }
            }
            .navigationTitle("history.title")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BrandLogo(size: .compact)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            showingHistoryHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .accessibilityLabel("history.help.label")
                        .accessibilityHint("history.help.hint")

                        if !viewModel.sessions.isEmpty {
                            Menu {
                                Button("history.action.exportAll") {
                                    viewModel.exportAllSessions()
                                }
                                .accessibilityHint("history.action.exportAll.hint")
                                Button("history.action.clear", role: .destructive) {
                                    viewModel.showClearConfirmation = true
                                }
                                .accessibilityHint("history.action.clear.hint")
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("history.options.label")
                            .accessibilityHint("history.options.hint")
                        }
                    }
                }
            }
            #endif
            .sheet(isPresented: $showingHistoryHelp) {
                HistoryHelpSheet()
            }
            .confirmationDialog(
                "history.clear.title",
                isPresented: $viewModel.showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("history.clear.confirm", role: .destructive) {
                    viewModel.clearHistory()
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("history.clear.message")
            }
            #if os(iOS)
            .sheet(isPresented: $viewModel.showExportSheet) {
                if let url = viewModel.exportURL {
                    ShareSheet(items: [url])
                }
            }
            #endif
            .task {
                Self.logger.info("HistoryView .task STARTED")
                await viewModel.loadAsync()
                Self.logger.info("HistoryView .task COMPLETED")
            }
        }
    }
}

// MARK: - Share Sheet

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - Empty State

struct EmptyHistoryView: View {
    var body: some View {
        ContentUnavailableView(
            "history.empty.title",
            systemImage: "clock.badge.questionmark",
            description: Text("history.empty.description")
        )
    }
}

// MARK: - Session List

struct SessionListView: View {
    let sessions: [SessionSummary]
    var onRefresh: (() async -> Void)?

    var body: some View {
        List {
            ForEach(groupedSessions, id: \.0) { date, daySessions in
                Section {
                    ForEach(daySessions) { session in
                        NavigationLink(destination: SessionDetailView(session: session)) {
                            SessionRowView(session: session)
                        }
                    }
                } header: {
                    Text(formatDate(date))
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .refreshable { await onRefresh?() }
    }

    private var groupedSessions: [(Date, [SessionSummary])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sessions) { session in
            calendar.startOfDay(for: session.startTime)
        }
        return grouped.sorted { $0.key > $1.key }
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return String(localized: "history.date.today")
        } else if calendar.isDateInYesterday(date) {
            return String(localized: "history.date.yesterday")
        } else {
            return date.formatted(.dateTime.year().month().day())
        }
    }
}

// MARK: - Session Row

struct SessionRowView: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.topicName ?? String(localized: "history.session.defaultTopic"))
                    .font(.headline)
                Spacer()
                Text(formatTime(session.startTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label(formatDuration(session.duration), systemImage: "clock")
                Label("history.session.turns \(session.turnCount)", systemImage: "message")
                Label(formatCost(session.totalCost), systemImage: "dollarsign.circle")
                if session.avgLatency > 0 {
                    Label(formatLatencyShort(session.avgLatency), systemImage: "bolt")
                        .foregroundStyle(latencyColor(session.avgLatency))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.topicName ?? String(localized: "history.session.defaultTopic"))
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint("history.session.a11y.hint")
    }

    /// Spoken summary of the row's metrics, including the latency status word that
    /// the latency color conveys visually.
    private var accessibilityValueText: String {
        var parts = [
            String(localized: "history.session.a11y.duration \(formatDuration(session.duration))"),
            String(localized: "history.session.a11y.turns \(session.turnCount)"),
            String(localized: "history.session.a11y.cost \(formatCost(session.totalCost))")
        ]
        if session.avgLatency > 0 {
            parts.append(String(localized: "history.session.a11y.latency \(formatLatencyShort(session.avgLatency)) \(latencyStatusText(session.avgLatency))"))
        }
        return parts.joined(separator: ", ")
    }

    private func formatTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond))
    }

    private func formatCost(_ cost: Decimal) -> String {
        cost.formatted(.currency(code: "USD"))
    }

    private func formatLatencyShort(_ latency: TimeInterval) -> String {
        String(localized: "history.latency.ms \(Int(latency * 1000))")
    }

    private func latencyColor(_ latency: TimeInterval) -> Color {
        let ms = Int(latency * 1000)
        if ms <= 300 { return .green }
        if ms <= 500 { return .yellow }
        return .red
    }

    private func latencyStatusText(_ latency: TimeInterval) -> String {
        let ms = Int(latency * 1000)
        if ms <= 300 { return String(localized: "history.latency.status.good") }
        if ms <= 500 { return String(localized: "history.latency.status.fair") }
        return String(localized: "history.latency.status.slow")
    }
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    let session: SessionSummary
    @StateObject private var detailViewModel = SessionDetailViewModel()
    @State private var exportURL: URL?
    @State private var showShareSheet = false

    private static let logger = Logger(label: "com.unamentis.ui.history.detail.view")

    var body: some View {
        ScrollView {
            if detailViewModel.isLoading {
                ProgressView("history.detail.loading")
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity)
            } else if let detail = detailViewModel.detail {
                LazyVStack(spacing: 16) {
                    SessionHeaderCard(detail: detail)

                    if let providerInfo = detail.metricsSnapshot?.providerInfo {
                        PipelineConfigCard(providerInfo: providerInfo)
                    }

                    if let latencies = detail.metricsSnapshot?.latencies {
                        LatencyBreakdownCard(latencies: latencies)
                    }

                    if let costs = detail.metricsSnapshot?.costs {
                        CostBreakdownCard(costs: costs, duration: detail.duration)
                    }

                    if let quality = detail.metricsSnapshot?.quality {
                        SessionQualityMetricsCard(quality: quality)
                    }

                    if let eventLog = detail.metricsSnapshot?.eventLog, !eventLog.isEmpty {
                        EventLogCard(events: eventLog)
                    }

                    FullTranscriptCard(entries: detail.transcript, sessionStart: detail.startTime)
                }
                .padding()
            } else {
                ContentUnavailableView(
                    "history.detail.error.title",
                    systemImage: "exclamationmark.triangle",
                    description: Text("history.detail.error.description")
                )
                .padding(.top, 60)
            }
        }
        .navigationTitle(session.topicName ?? String(localized: "history.detail.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        exportTranscript()
                    } label: {
                        Label("history.detail.export.transcript", systemImage: "doc.text")
                    }
                    .accessibilityHint("history.detail.export.transcript.hint")
                    Button {
                        shareSessionSummary()
                    } label: {
                        Label("history.detail.share.summary", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityHint("history.detail.share.summary.hint")
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("history.detail.export.label")
                .accessibilityHint("history.detail.export.hint")
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
        #endif
        .task {
            await detailViewModel.load(sessionID: session.id)
        }
    }

    private func exportTranscript() {
        let detail = detailViewModel.detail
        let entries = detail?.transcript ?? []
        let transcriptText = entries.map { entry in
            let role = String(localized: entry.isUser ? "history.role.you" : "history.role.ai")
            let time = HHmmssFormatter.string(from: entry.timestamp)
            return "[\(time)] \(role): \(entry.content)"
        }.joined(separator: "\n\n")

        let snapshot = detail?.metricsSnapshot
        let provider = snapshot?.providerInfo
        let latencies = snapshot?.latencies
        let topic = session.topicName ?? String(localized: "history.session.defaultTopic")

        var lines = [
            String(localized: "history.export.session \(topic)"),
            String(localized: "history.export.date \(formatExportDate(session.startTime))"),
            String(localized: "history.export.duration \(hhmmssFromInterval(session.duration))"),
            String(localized: "history.export.turns \(session.turnCount)"),
            String(localized: "history.export.cost \(formatCostPrecise(session.totalCost))")
        ]

        if let p = provider {
            lines.append(String(localized: "history.export.llm \(p.llmModel) \(p.llmProvider)"))
            lines.append(String(localized: "history.export.stt \(p.sttProvider)"))
            lines.append(String(localized: "history.export.tts \(p.ttsProvider)"))
        }
        if let l = latencies {
            lines.append(String(localized: "history.export.latency \(l.e2eMedianMs) \(l.e2eP99Ms)"))
        }

        let content = lines.joined(separator: "\n") + "\n\n---\n\n" + transcriptText

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "session_\(String(session.id.uuidString.prefix(8)))_transcript.txt"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            exportURL = fileURL
            showShareSheet = true
        } catch {
            Self.logger.error("Failed to export transcript: \(error.localizedDescription)")
        }
    }

    private func shareSessionSummary() {
        let snapshot = detailViewModel.detail?.metricsSnapshot
        let provider = snapshot?.providerInfo
        let latencies = snapshot?.latencies
        let topic = session.topicName ?? String(localized: "history.session.defaultTopic")

        var lines = [
            String(localized: "history.share.title"),
            String(localized: "history.share.topic \(topic)"),
            String(localized: "history.export.duration \(hhmmssFromInterval(session.duration))"),
            String(localized: "history.export.date \(formatExportDate(session.startTime))"),
            String(localized: "history.export.turns \(session.turnCount)"),
            String(localized: "history.export.cost \(formatCostPrecise(session.totalCost))")
        ]

        if let p = provider { lines.append(String(localized: "history.share.model \(p.llmModel)")) }
        if let l = latencies { lines.append(String(localized: "history.share.latency \(l.e2eMedianMs)")) }

        let content = lines.joined(separator: "\n")

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("session_summary.txt")

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            exportURL = fileURL
            showShareSheet = true
        } catch {
            Self.logger.error("Failed to share session: \(error.localizedDescription)")
        }
    }

    private func hhmmssFromInterval(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds)).formatted(
            .time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }

    private func formatExportDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func formatCostPrecise(_ cost: Decimal) -> String {
        let digits = cost < Decimal(0.001) ? 6 : 4
        return cost.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }
}

// MARK: - Shared UI Helpers

fileprivate extension View {
    func cardStyle() -> some View {
        self.padding()
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            }
    }
}

private struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String
    var valueColor: Color = .primary
    var labelWidth: CGFloat = 130

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(valueColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Combine reads the localized label Text and the verbatim value Text
        // together for VoiceOver.
        .accessibilityElement(children: .combine)
    }
}

private struct SectionDividerLabel: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 4)
    }
}

// MARK: - Session Header Card

private struct SessionHeaderCard: View {
    let detail: SessionDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("history.detail.header", systemImage: "clock.fill")
                    .font(.headline)
                Spacer()
                Text(durationString(detail.duration))
                    .font(.title2.monospacedDigit().bold())
            }

            Divider()

            InfoRow(label: "history.detail.topic", value: detail.topicName ?? String(localized: "history.session.defaultTopic"))
            if let curriculum = detail.curriculumName {
                InfoRow(label: "history.detail.curriculum", value: curriculum)
            }
            InfoRow(label: "history.detail.started", value: fullDateTimeString(detail.startTime))
            if let endTime = detail.endTime {
                InfoRow(label: "history.detail.ended", value: fullDateTimeString(endTime))
            }
            InfoRow(label: "history.detail.sessionId", value: detail.id.uuidString.lowercased())
        }
        .cardStyle()
    }

    private func durationString(_ t: TimeInterval) -> String {
        Duration.seconds(Int(t)).formatted(
            .time(pattern: t >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }

    private func fullDateTimeString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

// MARK: - Pipeline Config Card

private struct PipelineConfigCard: View {
    let providerInfo: SessionProviderInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("history.pipeline.title", systemImage: "cpu")
                .font(.headline)

            Divider()

            SectionDividerLabel(text: "history.pipeline.section.llm")
            InfoRow(label: "history.pipeline.model", value: providerInfo.llmModel)
            InfoRow(label: "history.pipeline.provider", value: providerInfo.llmProvider)
            InfoRow(label: "history.pipeline.temperature", value: Double(providerInfo.llmTemperature).formatted(.number.precision(.fractionLength(2))))
            InfoRow(label: "history.pipeline.maxTokens", value: providerInfo.llmMaxTokens.formatted())

            Divider()

            SectionDividerLabel(text: "history.pipeline.section.stt")
            InfoRow(label: "history.pipeline.provider", value: providerInfo.sttProvider)
            InfoRow(label: "history.pipeline.silenceThreshold", value: String(localized: "history.unit.seconds \(providerInfo.silenceThresholdSeconds.formatted(.number.precision(.fractionLength(1))))"))

            Divider()

            SectionDividerLabel(text: "history.pipeline.section.tts")
            InfoRow(label: "history.pipeline.provider", value: providerInfo.ttsProvider)
            InfoRow(label: "history.pipeline.voiceId", value: providerInfo.ttsVoiceId)
            InfoRow(label: "history.pipeline.rate", value: String(localized: "history.unit.rate \(Double(providerInfo.ttsRate).formatted(.number.precision(.fractionLength(2))))"))

            Divider()

            SectionDividerLabel(text: "history.pipeline.section.bargeIn")
            InfoRow(label: "history.pipeline.enabled", value: String(localized: providerInfo.bargeInEnabled ? "common.yes" : "common.no"))
            if providerInfo.bargeInEnabled {
                InfoRow(label: "history.pipeline.confirmation", value: String(localized: "history.latency.ms \(providerInfo.bargeInConfirmationMs)"))
            }

            Divider()

            SectionDividerLabel(text: "history.pipeline.section.systemPrompt")
            InfoRow(label: "history.pipeline.length", value: String(localized: "history.pipeline.charCount \(providerInfo.systemPromptCharCount)"))
        }
        .cardStyle()
    }
}

// MARK: - Latency Breakdown Card

private struct LatencyBreakdownCard: View {
    let latencies: LatencyMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("history.latency.title", systemImage: "bolt.fill")
                .font(.headline)

            Divider()

            HStack {
                Text("history.latency.column.stage")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("history.latency.column.median")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
                Text("history.latency.column.p99")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }

            SessionLatencyRow(
                stage: String(localized: "history.latency.stage.stt"),
                medianMs: latencies.sttMedianMs,
                p99Ms: latencies.sttP99Ms,
                okThreshold: 150, warnThreshold: 300
            )
            SessionLatencyRow(
                stage: String(localized: "history.latency.stage.llm"),
                medianMs: latencies.llmMedianMs,
                p99Ms: latencies.llmP99Ms,
                okThreshold: 200, warnThreshold: 400
            )
            SessionLatencyRow(
                stage: String(localized: "history.latency.stage.tts"),
                medianMs: latencies.ttsMedianMs,
                p99Ms: latencies.ttsP99Ms,
                okThreshold: 100, warnThreshold: 200
            )
            SessionLatencyRow(
                stage: String(localized: "history.latency.stage.e2e"),
                medianMs: latencies.e2eMedianMs,
                p99Ms: latencies.e2eP99Ms,
                okThreshold: 300, warnThreshold: 500
            )
            if let ttfaMedian = latencies.ttfaMedianMs, let ttfaP99 = latencies.ttfaP99Ms {
                SessionLatencyRow(
                    stage: String(localized: "history.latency.stage.ttfa"),
                    medianMs: ttfaMedian,
                    p99Ms: ttfaP99,
                    okThreshold: 400, warnThreshold: 700
                )
            }

            Text("history.latency.target")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .cardStyle()
    }
}

private struct SessionLatencyRow: View {
    let stage: String
    let medianMs: Int
    let p99Ms: Int
    let okThreshold: Int
    let warnThreshold: Int

    var body: some View {
        HStack {
            Text(stage)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(msString(medianMs))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(colorFor(medianMs))
                .frame(width: 72, alignment: .trailing)
            Text(msString(p99Ms))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(colorFor(p99Ms))
                .frame(width: 72, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "history.latency.a11y.label \(stage) \(medianMs) \(p99Ms)"))
        .accessibilityValue(statusText)
    }

    /// Localized status word matching the latency color, so VoiceOver conveys the
    /// same good/fair/slow state the color shows visually. Reflects the worse of
    /// the median and P99 figures.
    private var statusText: String {
        switch max(statusRank(medianMs), statusRank(p99Ms)) {
        case 0: return String(localized: "history.latency.status.good")
        case 1: return String(localized: "history.latency.status.fair")
        default: return String(localized: "history.latency.status.slow")
        }
    }

    private func statusRank(_ ms: Int) -> Int {
        guard ms > 0 else { return 0 }
        if ms <= okThreshold { return 0 }
        if ms <= warnThreshold { return 1 }
        return 2
    }

    private func msString(_ ms: Int) -> String {
        ms == 0 ? "--" : String(localized: "history.latency.ms \(ms)")
    }

    private func colorFor(_ ms: Int) -> Color {
        guard ms > 0 else { return .secondary }
        if ms <= okThreshold { return .green }
        if ms <= warnThreshold { return .yellow }
        return .red
    }
}

// MARK: - Cost Breakdown Card

private struct CostBreakdownCard: View {
    let costs: CostMetrics
    let duration: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("history.cost.title", systemImage: "dollarsign.circle.fill")
                .font(.headline)

            Divider()

            InfoRow(label: "history.cost.stt", value: costString(costs.sttTotal))
            InfoRow(label: "history.cost.tts", value: costString(costs.ttsTotal))
            InfoRow(label: "history.cost.llm", value: costString(costs.llmTotal))
            InfoRow(
                label: "history.cost.tokens",
                value: String(localized: "history.cost.tokens.value \(costs.llmInputTokens) \(costs.llmOutputTokens)")
            )

            Divider()

            HStack {
                Text("history.cost.total")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(costString(costs.totalSession))
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityElement(children: .combine)

            if duration > 0 {
                let rate = NSDecimalNumber(decimal: costs.totalSession).doubleValue * 3600.0 / duration
                InfoRow(
                    label: "history.cost.hourly",
                    value: String(localized: "history.cost.perHour \(Decimal(rate).formatted(.currency(code: "USD")))"),
                    valueColor: .secondary
                )
            }
        }
        .cardStyle()
    }

    private func costString(_ cost: Decimal) -> String {
        let digits: Int = (cost > 0 && cost < Decimal(0.001)) ? 6 : 4
        return cost.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }
}

// MARK: - Quality Metrics Card

private struct SessionQualityMetricsCard: View {
    let quality: QualityMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("history.quality.title", systemImage: "chart.bar.fill")
                .font(.headline)

            Divider()

            InfoRow(label: "history.quality.turns", value: quality.turnsTotal.formatted())
            InfoRow(label: "history.quality.interruptions", value: quality.interruptions.formatted())
            if quality.turnsTotal > 0 && quality.interruptions > 0 {
                let rate = Double(quality.interruptions) / Double(quality.turnsTotal)
                InfoRow(label: "history.quality.interruptRate", value: rate.formatted(.percent.precision(.fractionLength(1))))
            }

            Divider()

            let totalErrors = quality.errorsTotal ?? 0
            InfoRow(
                label: "history.quality.errors",
                value: totalErrors.formatted(),
                valueColor: totalErrors > 0 ? .red : .primary
            )

            if let byStage = quality.errorsByStage, !byStage.isEmpty {
                let sorted = byStage.sorted(by: { $0.key < $1.key })
                ForEach(0..<sorted.count, id: \.self) { i in
                    InfoRow(
                        label: "history.quality.errorStage \(sorted[i].key.uppercased())",
                        value: String(localized: "history.quality.errorCount \(sorted[i].value)"),
                        valueColor: sorted[i].value > 0 ? .red : .secondary
                    )
                }
            }

            Divider()

            InfoRow(
                label: "history.quality.thermal",
                value: quality.thermalThrottleEvents.formatted(),
                valueColor: quality.thermalThrottleEvents > 0 ? .orange : .primary
            )
            InfoRow(
                label: "history.quality.network",
                value: quality.networkDegradations.formatted(),
                valueColor: quality.networkDegradations > 0 ? .orange : .primary
            )
        }
        .cardStyle()
    }
}

// MARK: - Event Log Card

private struct EventLogCard: View {
    let events: [SessionEventRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("history.eventLog.title \(events.count)", systemImage: "list.bullet.clipboard")
                .font(.headline)

            Divider()

            ForEach(0..<events.count, id: \.self) { i in
                EventLogRow(record: events[i])
                if i < events.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
        .cardStyle()
    }
}

private struct EventLogRow: View {
    let record: SessionEventRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(offsetString(record.offsetSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            Text(eventLabel(record.type))
                .font(.caption.weight(.semibold))
                .foregroundStyle(eventColor(record.type))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(eventColor(record.type).opacity(0.15))
                }
                .frame(width: 90, alignment: .leading)

            Text(localizedDetail(record))
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "history.eventLog.a11y \(offsetString(record.offsetSeconds)) \(eventLabel(record.type)) \(localizedDetail(record))"))
    }

    private func offsetString(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "+%d:%02d", m, s)
    }

    private func eventLabel(_ type: String) -> String {
        switch type {
        case "stt_error": return String(localized: "history.event.label.sttError")
        case "llm_error": return String(localized: "history.event.label.llmError")
        case "tts_error": return String(localized: "history.event.label.ttsError")
        case "thermal_change": return String(localized: "history.event.label.thermal")
        case "context_compressed": return String(localized: "history.event.label.contextCompressed")
        case "barge_in": return String(localized: "history.event.label.bargeIn")
        case "quality_adjusted": return String(localized: "history.event.label.qualityAdjusted")
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Build the localized, PII-free detail text from the record's `type` and
    /// structured `detail` token. Older records that stored free-form prose fall
    /// back to showing that text verbatim.
    private func localizedDetail(_ record: SessionEventRecord) -> String {
        switch record.type {
        case "stt_error": return String(localized: "history.event.detail.sttError")
        case "llm_error": return String(localized: "history.event.detail.llmError")
        case "tts_error": return String(localized: "history.event.detail.ttsError")
        case "thermal_change":
            return String(localized: "history.event.detail.thermal \(thermalStateLabel(record.detail))")
        case "context_compressed":
            let parts = record.detail.split(separator: "|")
            if parts.count == 2, let from = Int(parts[0]), let to = Int(parts[1]) {
                return String(localized: "history.event.detail.contextCompressed \(from) \(to)")
            }
            return record.detail
        case "barge_in": return String(localized: "history.event.detail.bargeIn")
        case "quality_adjusted":
            return record.detail.isEmpty
                ? String(localized: "history.event.detail.qualityAdjusted.generic")
                : String(localized: "history.event.detail.qualityAdjusted \(record.detail)")
        default: return record.detail
        }
    }

    private func thermalStateLabel(_ token: String) -> String {
        switch token {
        case "nominal": return String(localized: "history.thermal.nominal")
        case "fair": return String(localized: "history.thermal.fair")
        case "serious": return String(localized: "history.thermal.serious")
        case "critical": return String(localized: "history.thermal.critical")
        default: return token
        }
    }

    private func eventColor(_ type: String) -> Color {
        switch type {
        case "stt_error", "llm_error", "tts_error": return .red
        case "thermal_change": return .orange
        case "context_compressed": return .purple
        case "barge_in": return .blue
        case "quality_adjusted": return .yellow
        default: return .secondary
        }
    }
}

// MARK: - Full Transcript Card

private struct FullTranscriptCard: View {
    let entries: [TranscriptDetailEntry]
    let sessionStart: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("history.transcript.title \(entries.count)", systemImage: "text.quote")
                .font(.headline)

            Divider()

            if entries.isEmpty {
                Text("history.detail.transcript.empty")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        TranscriptEntryRow(entry: entry, sessionStart: sessionStart)
                    }
                }
            }
        }
        .cardStyle()
    }
}

private struct TranscriptEntryRow: View {
    let entry: TranscriptDetailEntry
    let sessionStart: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: entry.isUser ? "person.fill" : "cpu")
                    .font(.caption)
                    .foregroundStyle(entry.isUser ? .blue : .purple)
                Text(entry.isUser ? "history.role.you" : "history.role.ai")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(entry.isUser ? .blue : .purple)
                Text(HHmmssFormatter.string(from: entry.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(offsetString(entry.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(entry.content)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(entry.isUser ? Color.blue.opacity(0.08) : Color.purple.opacity(0.08))
                }
        }
        .padding(.bottom, 6)
        // Role + time is the accessibility label; the spoken content is the value,
        // so VoiceOver announces who spoke separately from what was said.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "history.transcript.a11y.role \(String(localized: entry.isUser ? "history.role.you" : "history.role.ai")) \(HHmmssFormatter.string(from: entry.timestamp))"))
        .accessibilityValue(entry.content)
    }

    private func offsetString(_ date: Date) -> String {
        let offset = date.timeIntervalSince(sessionStart)
        let m = Int(max(offset, 0)) / 60
        let s = Int(max(offset, 0)) % 60
        return String(format: "+%d:%02d", m, s)
    }
}

// MARK: - Date Formatter Helpers

private enum HHmmssFormatter {
    static func string(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

// MARK: - Session Detail View Model

@MainActor
final class SessionDetailViewModel: ObservableObject {
    @Published private(set) var detail: SessionDetail?
    @Published private(set) var isLoading = false

    private let persistence = PersistenceController.shared
    private let logger = Logger(label: "com.unamentis.ui.history.detail")

    /// Load the full detail for a session. Runs the Core Data fetch on a
    /// background context via `perform` (the established pattern in this app);
    /// `SessionDetail` is `Sendable`, so the result returns to the main actor
    /// without an extra `Task.detached` hop.
    func load(sessionID: UUID) async {
        guard detail == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let ctx = persistence.newBackgroundContext()

        detail = await ctx.perform { [logger] () -> SessionDetail? in
            let request = Session.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", sessionID as CVarArg)
            request.fetchLimit = 1
            request.relationshipKeyPathsForPrefetching = ["topic", "topic.curriculum", "transcript"]

            guard let session = try? ctx.fetch(request).first,
                  let sid = session.id,
                  let startTime = session.startTime else {
                logger.warning("Session not found: \(sessionID)")
                return nil
            }

            let topicName = session.topic?.title
            let curriculumName = session.topic?.curriculum?.name

            var metricsSnapshot: MetricsSnapshot?
            if let data = session.metricsSnapshot {
                metricsSnapshot = try? JSONDecoder().decode(MetricsSnapshot.self, from: data)
            }

            var sessionConfig: SessionConfig?
            if let data = session.config {
                sessionConfig = try? JSONDecoder().decode(SessionConfig.self, from: data)
            }

            let rawEntries = (session.transcript?.array as? [TranscriptEntry]) ?? []
            let transcriptEntries: [TranscriptDetailEntry] = rawEntries.compactMap { entry in
                guard let eid = entry.id,
                      let content = entry.content,
                      let role = entry.role,
                      let ts = entry.timestamp else { return nil }
                return TranscriptDetailEntry(
                    id: eid,
                    isUser: role == "user",
                    content: content,
                    timestamp: ts
                )
            }

            return SessionDetail(
                id: sid,
                startTime: startTime,
                endTime: session.endTime,
                duration: session.duration,
                topicName: topicName,
                curriculumName: curriculumName,
                metricsSnapshot: metricsSnapshot,
                sessionConfig: sessionConfig,
                transcript: transcriptEntries
            )
        }
    }
}

// MARK: - Data Models

struct TranscriptDetailEntry: Identifiable, Sendable {
    let id: UUID
    let isUser: Bool
    let content: String
    let timestamp: Date
}

struct SessionDetail: Sendable {
    let id: UUID
    let startTime: Date
    let endTime: Date?
    let duration: TimeInterval
    let topicName: String?
    let curriculumName: String?
    let metricsSnapshot: MetricsSnapshot?
    let sessionConfig: SessionConfig?
    let transcript: [TranscriptDetailEntry]
}

struct SessionSummary: Identifiable, Sendable {
    let id: UUID
    let startTime: Date
    let duration: TimeInterval
    let topicName: String?
    let turnCount: Int
    let totalCost: Decimal
    let avgLatency: TimeInterval
    let transcriptPreview: [TranscriptPreview]
}

struct TranscriptPreview: Identifiable, Sendable {
    let id = UUID()
    let isUser: Bool
    let content: String
}

// MARK: - History View Model

@MainActor
class HistoryViewModel: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var showClearConfirmation = false
    @Published var exportURL: URL?
    @Published var showExportSheet = false

    private let persistence = PersistenceController.shared
    private let logger = Logger(label: "com.unamentis.ui.history")
    private var hasLoaded = false

    init() {}

    /// Initial load for the History tab. The gate only suppresses repeat work
    /// once a load has succeeded, so a transient failure on first appearance can
    /// still be retried, and `refresh()` provides an explicit force-reload path.
    func loadAsync() async {
        guard !hasLoaded else { return }
        await loadFromCoreDataAsync()
        hasLoaded = true
    }

    /// Force a reload regardless of the initial-load gate (pull-to-refresh, or
    /// after a new session is recorded while the tab is already on screen).
    func refresh() async {
        await loadFromCoreDataAsync()
    }

    private func loadFromCoreDataAsync() async {
        let ctx = persistence.newBackgroundContext()

        let summaries: [SessionSummary] = await ctx.perform { [logger] () -> [SessionSummary] in
            let request = Session.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Session.startTime, ascending: false)]
            request.fetchLimit = 100
            request.relationshipKeyPathsForPrefetching = ["topic", "transcript"]

            do {
                let rows = try ctx.fetch(request)
                logger.info("Fetched \(rows.count) sessions from Core Data")

                return rows.compactMap { session -> SessionSummary? in
                    guard let id = session.id, let startTime = session.startTime else { return nil }

                    let topicName = session.topic?.title
                    let entries = (session.transcript?.array as? [TranscriptEntry]) ?? []
                    let preview = entries.prefix(3).compactMap { entry -> TranscriptPreview? in
                        guard let content = entry.content, let role = entry.role else { return nil }
                        return TranscriptPreview(isUser: role == "user", content: String(content.prefix(100)))
                    }

                    var avgLatency: TimeInterval = 0
                    if let data = session.metricsSnapshot,
                       let snap = try? JSONDecoder().decode(MetricsSnapshot.self, from: data) {
                        avgLatency = TimeInterval(snap.latencies.e2eMedianMs) / 1000.0
                    } else if let data = session.metricsSnapshot,
                              let legacy = try? JSONDecoder().decode(SessionMetricsData.self, from: data),
                              let lat = legacy.avgLatency {
                        avgLatency = lat
                    }

                    return SessionSummary(
                        id: id,
                        startTime: startTime,
                        duration: session.duration,
                        topicName: topicName,
                        turnCount: entries.count,
                        totalCost: session.totalCost as Decimal? ?? 0,
                        avgLatency: avgLatency,
                        transcriptPreview: preview
                    )
                }
            } catch {
                logger.error("Fetch error: \(error)")
                return []
            }
        }

        self.sessions = summaries
    }

    func loadFromCoreData() {
        Task { await loadFromCoreDataAsync() }
    }

    func exportAllSessions() {
        do {
            let rows = try persistence.fetchRecentSessions(limit: 1000)
            let exportData: [[String: Any]] = rows.map { session in
                var dict: [String: Any] = [
                    "id": session.id?.uuidString ?? "",
                    "startTime": session.startTime?.ISO8601Format() ?? "",
                    "duration": session.duration,
                    "totalCost": (session.totalCost as NSDecimalNumber?)?.doubleValue ?? 0
                ]
                if let topic = session.topic {
                    dict["topic"] = topic.title ?? "Unknown"
                }
                if let entries = session.transcript?.array as? [TranscriptEntry] {
                    dict["transcript"] = entries.map { entry in
                        [
                            "role": entry.role ?? "unknown",
                            "content": entry.content ?? "",
                            "timestamp": entry.timestamp?.ISO8601Format() ?? ""
                        ]
                    }
                }
                // Embed the full observability snapshot (provider info, latency
                // breakdown, costs/tokens, event log) and the session config so
                // the all-sessions export carries the same detail the History UI
                // shows. Stored blobs are already JSON, so re-parse them in place.
                if let data = session.metricsSnapshot,
                   let metrics = try? JSONSerialization.jsonObject(with: data) {
                    dict["metrics"] = metrics
                }
                if let data = session.config,
                   let config = try? JSONSerialization.jsonObject(with: data) {
                    dict["config"] = config
                }
                return dict
            }

            let jsonData = try JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted)
            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent("unamentis_sessions_\(Date().ISO8601Format()).json")
            try jsonData.write(to: fileURL)
            exportURL = fileURL
            showExportSheet = true
        } catch {
            logger.error("Export error: \(error.localizedDescription)")
        }
    }

    func clearHistory() {
        let ctx = persistence.viewContext
        let request = Session.fetchRequest()
        do {
            let rows = try ctx.fetch(request)
            for row in rows { ctx.delete(row) }
            try persistence.save()
            sessions.removeAll()
        } catch {
            logger.error("Clear error: \(error.localizedDescription)")
        }
    }
}

// Decodes the legacy metrics blob format used before MetricsSnapshot was introduced
private struct SessionMetricsData: Codable {
    let avgLatency: TimeInterval?
    let totalCost: Double?
}

// MARK: - History Help Sheet

struct HistoryHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("history.help.intro")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }

                Section("history.help.section.metrics") {
                    HistoryHelpRow(
                        icon: "clock.fill",
                        iconColor: .green,
                        title: "history.help.duration.title",
                        description: "history.help.duration.desc"
                    )
                    HistoryHelpRow(
                        icon: "message.fill",
                        iconColor: .blue,
                        title: "history.help.turns.title",
                        description: "history.help.turns.desc"
                    )
                    HistoryHelpRow(
                        icon: "dollarsign.circle.fill",
                        iconColor: .orange,
                        title: "history.help.cost.title",
                        description: "history.help.cost.desc"
                    )
                    HistoryHelpRow(
                        icon: "bolt.fill",
                        iconColor: .purple,
                        title: "history.help.latency.title",
                        description: "history.help.latency.desc"
                    )
                }

                Section("history.help.section.targets") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("history.help.target.median"); Spacer()
                            Text("history.help.target.median.value").foregroundStyle(.green)
                        }
                        HStack {
                            Text("history.help.target.p99"); Spacer()
                            Text("history.help.target.p99.value").foregroundStyle(.green)
                        }
                        HStack {
                            Text("history.help.target.cost"); Spacer()
                            Text("history.help.target.cost.value").foregroundStyle(.green)
                        }
                    }
                    .font(.subheadline)
                }

                Section("history.help.section.detail") {
                    HistoryHelpRow(
                        icon: "cpu",
                        iconColor: .indigo,
                        title: "history.help.pipeline.title",
                        description: "history.help.pipeline.desc"
                    )
                    HistoryHelpRow(
                        icon: "bolt.fill",
                        iconColor: .yellow,
                        title: "history.help.latencyBreakdown.title",
                        description: "history.help.latencyBreakdown.desc"
                    )
                    HistoryHelpRow(
                        icon: "dollarsign.circle.fill",
                        iconColor: .orange,
                        title: "history.help.costBreakdown.title",
                        description: "history.help.costBreakdown.desc"
                    )
                    HistoryHelpRow(
                        icon: "list.bullet.clipboard",
                        iconColor: .purple,
                        title: "history.help.eventLog.title",
                        description: "history.help.eventLog.desc"
                    )
                    HistoryHelpRow(
                        icon: "text.quote",
                        iconColor: .blue,
                        title: "history.help.transcript.title",
                        description: "history.help.transcript.desc"
                    )
                }

                Section("history.help.section.export") {
                    Text("history.help.export.desc")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
            .navigationTitle("history.help.title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
        }
    }
}

private struct HistoryHelpRow: View {
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        // Combine reads the localized title and description Texts together.
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preview

#Preview {
    HistoryView()
}

#Preview("History Help") {
    HistoryHelpSheet()
}
