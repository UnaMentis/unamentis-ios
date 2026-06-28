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
                    SessionListView(sessions: viewModel.sessions)
                }
            }
            .navigationTitle("History")
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
                        .accessibilityLabel("History help")
                        .accessibilityHint("Learn about session history and metrics")

                        if !viewModel.sessions.isEmpty {
                            Menu {
                                Button("Export All") {
                                    viewModel.exportAllSessions()
                                }
                                Button("Clear History", role: .destructive) {
                                    viewModel.showClearConfirmation = true
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("History options")
                        }
                    }
                }
            }
            #endif
            .sheet(isPresented: $showingHistoryHelp) {
                HistoryHelpSheet()
            }
            .confirmationDialog(
                "Clear History",
                isPresented: $viewModel.showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All Sessions", role: .destructive) {
                    viewModel.clearHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all session history.")
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
            "No Sessions Yet",
            systemImage: "clock.badge.questionmark",
            description: Text("Your conversation history will appear here after your first session.")
        )
    }
}

// MARK: - Session List

struct SessionListView: View {
    let sessions: [SessionSummary]

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
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        }
    }
}

// MARK: - Session Row

struct SessionRowView: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.topicName ?? "General Conversation")
                    .font(.headline)
                Spacer()
                Text(formatTime(session.startTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label(formatDuration(session.duration), systemImage: "clock")
                Label("\(session.turnCount) turns", systemImage: "message")
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
        .accessibilityLabel("\(session.topicName ?? "General Conversation")")
        .accessibilityValue(
            "Duration \(formatDuration(session.duration)), \(session.turnCount) turns, " +
            "cost \(formatCost(session.totalCost))\(session.avgLatency > 0 ? ", avg latency \(formatLatencyShort(session.avgLatency))" : "")"
        )
        .accessibilityHint("Double-tap to view session details")
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    private func formatCost(_ cost: Decimal) -> String {
        String(format: "$%.2f", NSDecimalNumber(decimal: cost).doubleValue)
    }

    private func formatLatencyShort(_ latency: TimeInterval) -> String {
        let ms = Int(latency * 1000)
        return "\(ms)ms"
    }

    private func latencyColor(_ latency: TimeInterval) -> Color {
        let ms = Int(latency * 1000)
        if ms <= 300 { return .green }
        if ms <= 500 { return .yellow }
        return .red
    }
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    let session: SessionSummary
    @StateObject private var detailViewModel: SessionDetailViewModel
    @State private var exportURL: URL?
    @State private var showShareSheet = false

    init(session: SessionSummary) {
        self.session = session
        _detailViewModel = StateObject(wrappedValue: SessionDetailViewModel(sessionID: session.id))
    }

    var body: some View {
        ScrollView {
            if detailViewModel.isLoading {
                ProgressView("Loading session details...")
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity)
            } else if let detail = detailViewModel.detail {
                VStack(spacing: 16) {
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
                        QualityMetricsCard(quality: quality)
                    }

                    if let eventLog = detail.metricsSnapshot?.eventLog, !eventLog.isEmpty {
                        EventLogCard(events: eventLog)
                    }

                    FullTranscriptCard(entries: detail.transcript, sessionStart: detail.startTime)
                }
                .padding()
            } else {
                ContentUnavailableView(
                    "Could not load session",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Session data could not be read from storage.")
                )
                .padding(.top, 60)
            }
        }
        .navigationTitle(session.topicName ?? "Session Details")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        exportTranscript()
                    } label: {
                        Label("Export Transcript", systemImage: "doc.text")
                    }
                    Button {
                        shareSessionSummary()
                    } label: {
                        Label("Share Summary", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Export options")
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
        #endif
        .task {
            await detailViewModel.load()
        }
    }

    private func exportTranscript() {
        let detail = detailViewModel.detail
        let entries = detail?.transcript ?? []
        let transcriptText = entries.map { entry in
            let role = entry.isUser ? "You" : "AI"
            let time = HHmmssFormatter.string(from: entry.timestamp)
            return "[\(time)] \(role): \(entry.content)"
        }.joined(separator: "\n\n")

        let snapshot = detail?.metricsSnapshot
        let provider = snapshot?.providerInfo
        let latencies = snapshot?.latencies

        var header = """
        Session: \(session.topicName ?? "General Conversation")
        Date: \(mediumDateTimeFormatter.string(from: session.startTime))
        Duration: \(hhmmssFromInterval(session.duration))
        Turns: \(session.turnCount)
        Cost: \(formatCostPrecise(session.totalCost))
        """

        if let p = provider {
            header += "\nLLM: \(p.llmModel) (\(p.llmProvider))"
            header += "\nSTT: \(p.sttProvider)"
            header += "\nTTS: \(p.ttsProvider)"
        }
        if let l = latencies {
            header += "\nE2E Latency: \(l.e2eMedianMs)ms median / \(l.e2eP99Ms)ms P99"
        }

        let content = header + "\n\n---\n\n" + transcriptText

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "session_\(String(session.id.uuidString.prefix(8)))_transcript.txt"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            exportURL = fileURL
            showShareSheet = true
        } catch {
            print("Failed to export transcript: \(error)")
        }
    }

    private func shareSessionSummary() {
        let snapshot = detailViewModel.detail?.metricsSnapshot
        let provider = snapshot?.providerInfo
        let latencies = snapshot?.latencies

        var content = """
        Learning Session Summary
        Topic: \(session.topicName ?? "General Conversation")
        Duration: \(hhmmssFromInterval(session.duration))
        Date: \(mediumDateTimeFormatter.string(from: session.startTime))
        Turns: \(session.turnCount)
        Cost: \(formatCostPrecise(session.totalCost))
        """

        if let p = provider { content += "\nModel: \(p.llmModel)" }
        if let l = latencies { content += "\nE2E Latency: \(l.e2eMedianMs)ms median" }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("session_summary.txt")

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            exportURL = fileURL
            showShareSheet = true
        } catch {
            print("Failed to share session: \(error)")
        }
    }

    private func hhmmssFromInterval(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private var mediumDateTimeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    private func formatCostPrecise(_ cost: Decimal) -> String {
        let v = NSDecimalNumber(decimal: cost).doubleValue
        return v < 0.001 ? String(format: "$%.6f", v) : String(format: "$%.4f", v)
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
    let label: String
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

private struct SectionDividerLabel: View {
    let text: String

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
                Label("Session", systemImage: "clock.fill")
                    .font(.headline)
                Spacer()
                Text(durationString(detail.duration))
                    .font(.title2.monospacedDigit().bold())
            }

            Divider()

            InfoRow(label: "Topic", value: detail.topicName ?? "General Conversation")
            if let curriculum = detail.curriculumName {
                InfoRow(label: "Curriculum", value: curriculum)
            }
            InfoRow(label: "Started", value: fullDateTimeString(detail.startTime))
            if let endTime = detail.endTime {
                InfoRow(label: "Ended", value: fullDateTimeString(endTime))
            }
            InfoRow(label: "Session ID", value: detail.id.uuidString.lowercased())
        }
        .cardStyle()
    }

    private func durationString(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func fullDateTimeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }
}

// MARK: - Pipeline Config Card

private struct PipelineConfigCard: View {
    let providerInfo: ProviderInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pipeline Configuration", systemImage: "cpu")
                .font(.headline)

            Divider()

            SectionDividerLabel(text: "LLM")
            InfoRow(label: "Model", value: providerInfo.llmModel)
            InfoRow(label: "Provider", value: providerInfo.llmProvider)
            InfoRow(label: "Temperature", value: String(format: "%.2f", providerInfo.llmTemperature))
            InfoRow(label: "Max Tokens", value: providerInfo.llmMaxTokens.formatted())

            Divider()

            SectionDividerLabel(text: "Speech Recognition")
            InfoRow(label: "Provider", value: providerInfo.sttProvider)
            InfoRow(label: "Silence Threshold", value: String(format: "%.1fs", providerInfo.silenceThresholdSeconds))

            Divider()

            SectionDividerLabel(text: "Speech Synthesis")
            InfoRow(label: "Provider", value: providerInfo.ttsProvider)
            InfoRow(label: "Voice ID", value: providerInfo.ttsVoiceId)
            InfoRow(label: "Rate", value: String(format: "%.2fx", providerInfo.ttsRate))

            Divider()

            SectionDividerLabel(text: "Barge-in")
            InfoRow(label: "Enabled", value: providerInfo.bargeInEnabled ? "Yes" : "No")
            if providerInfo.bargeInEnabled {
                InfoRow(label: "Confirmation", value: "\(providerInfo.bargeInConfirmationMs)ms")
            }

            Divider()

            SectionDividerLabel(text: "System Prompt")
            InfoRow(label: "Length", value: "\(providerInfo.systemPromptCharCount.formatted()) characters")
        }
        .cardStyle()
    }
}

// MARK: - Latency Breakdown Card

private struct LatencyBreakdownCard: View {
    let latencies: LatencyMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Latency Breakdown", systemImage: "bolt.fill")
                .font(.headline)

            Divider()

            HStack {
                Text("Stage")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Median")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
                Text("P99")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }

            LatencyRow(
                stage: "STT Emission",
                medianMs: latencies.sttMedianMs,
                p99Ms: latencies.sttP99Ms,
                okThreshold: 150, warnThreshold: 300
            )
            LatencyRow(
                stage: "LLM First Token",
                medianMs: latencies.llmMedianMs,
                p99Ms: latencies.llmP99Ms,
                okThreshold: 200, warnThreshold: 400
            )
            LatencyRow(
                stage: "TTS First Byte",
                medianMs: latencies.ttsMedianMs,
                p99Ms: latencies.ttsP99Ms,
                okThreshold: 100, warnThreshold: 200
            )
            LatencyRow(
                stage: "End-to-End Turn",
                medianMs: latencies.e2eMedianMs,
                p99Ms: latencies.e2eP99Ms,
                okThreshold: 300, warnThreshold: 500
            )
            if let ttfaMedian = latencies.ttfaMedianMs, let ttfaP99 = latencies.ttfaP99Ms {
                LatencyRow(
                    stage: "TTFA",
                    medianMs: ttfaMedian,
                    p99Ms: ttfaP99,
                    okThreshold: 400, warnThreshold: 700
                )
            }

            Text("Target: E2E <500ms median, <1000ms P99")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .cardStyle()
    }
}

private struct LatencyRow: View {
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
        .accessibilityLabel("\(stage): \(medianMs) milliseconds median, \(p99Ms) milliseconds P99")
    }

    private func msString(_ ms: Int) -> String {
        ms == 0 ? "--" : "\(ms)ms"
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
            Label("Cost Breakdown", systemImage: "dollarsign.circle.fill")
                .font(.headline)

            Divider()

            InfoRow(label: "STT", value: costString(costs.sttTotal))
            InfoRow(label: "TTS", value: costString(costs.ttsTotal))
            InfoRow(label: "LLM", value: costString(costs.llmTotal))
            InfoRow(
                label: "LLM Tokens",
                value: "\(costs.llmInputTokens.formatted()) in / \(costs.llmOutputTokens.formatted()) out"
            )

            Divider()

            HStack {
                Text("Session Total")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(costString(costs.totalSession))
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Session total: \(costString(costs.totalSession))")

            if duration > 0 {
                let rate = NSDecimalNumber(decimal: costs.totalSession).doubleValue * 3600.0 / duration
                InfoRow(label: "Hourly Rate", value: String(format: "$%.2f/hr", rate), valueColor: .secondary)
            }
        }
        .cardStyle()
    }

    private func costString(_ cost: Decimal) -> String {
        let v = NSDecimalNumber(decimal: cost).doubleValue
        if v == 0 { return "$0.0000" }
        if v < 0.001 { return String(format: "$%.6f", v) }
        return String(format: "$%.4f", v)
    }
}

// MARK: - Quality Metrics Card

private struct QualityMetricsCard: View {
    let quality: QualityMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Quality Metrics", systemImage: "chart.bar.fill")
                .font(.headline)

            Divider()

            InfoRow(label: "Total Turns", value: "\(quality.turnsTotal)")
            InfoRow(label: "Interruptions", value: "\(quality.interruptions)")
            if quality.turnsTotal > 0 && quality.interruptions > 0 {
                let rate = Float(quality.interruptions) / Float(quality.turnsTotal) * 100
                InfoRow(label: "Interrupt Rate", value: String(format: "%.1f%%", rate))
            }

            Divider()

            let totalErrors = quality.errorsTotal ?? 0
            InfoRow(
                label: "Total Errors",
                value: "\(totalErrors)",
                valueColor: totalErrors > 0 ? .red : .primary
            )

            if let byStage = quality.errorsByStage, !byStage.isEmpty {
                let sorted = byStage.sorted(by: { $0.key < $1.key })
                ForEach(0..<sorted.count, id: \.self) { i in
                    InfoRow(
                        label: "  \(sorted[i].key.uppercased())",
                        value: "\(sorted[i].value) errors",
                        valueColor: sorted[i].value > 0 ? .red : .secondary
                    )
                }
            }

            Divider()

            InfoRow(
                label: "Thermal Events",
                value: "\(quality.thermalThrottleEvents)",
                valueColor: quality.thermalThrottleEvents > 0 ? .orange : .primary
            )
            InfoRow(
                label: "Network Drops",
                value: "\(quality.networkDegradations)",
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
            Label("Event Log (\(events.count))", systemImage: "list.bullet.clipboard")
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

            Text(record.detail)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(offsetString(record.offsetSeconds)): \(eventLabel(record.type)): \(record.detail)")
    }

    private func offsetString(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "+%d:%02d", m, s)
    }

    private func eventLabel(_ type: String) -> String {
        switch type {
        case "stt_error": return "STT Error"
        case "llm_error": return "LLM Error"
        case "tts_error": return "TTS Error"
        case "thermal_change": return "Thermal"
        case "context_compressed": return "Ctx Compress"
        case "barge_in": return "Barge-in"
        case "quality_adjusted": return "Quality Adj"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
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
            Label("Full Transcript (\(entries.count) messages)", systemImage: "text.quote")
                .font(.headline)

            Divider()

            if entries.isEmpty {
                Text("No transcript entries")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    TranscriptEntryRow(entry: entry, sessionStart: sessionStart)
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
                Text(entry.isUser ? "You" : "AI")
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.isUser ? "You" : "AI") at \(HHmmssFormatter.string(from: entry.timestamp)): \(entry.content)"
        )
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

    private let sessionID: UUID
    private let persistence = PersistenceController.shared
    private let logger = Logger(label: "com.unamentis.ui.history.detail")

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    func load() async {
        guard detail == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let targetID = sessionID
        let ctx = persistence.newBackgroundContext()

        detail = await Task.detached(priority: .userInitiated) { [logger] in
            await ctx.perform { () -> SessionDetail? in
                let request = Session.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", targetID as CVarArg)
                request.fetchLimit = 1
                request.relationshipKeyPathsForPrefetching = ["topic", "topic.curriculum", "transcript"]

                guard let session = try? ctx.fetch(request).first,
                      let sid = session.id,
                      let startTime = session.startTime else {
                    logger.warning("Session not found: \(targetID)")
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
        }.value
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

struct SessionSummary: Identifiable {
    let id: UUID
    let startTime: Date
    let duration: TimeInterval
    let topicName: String?
    let turnCount: Int
    let totalCost: Decimal
    let avgLatency: TimeInterval
    let transcriptPreview: [TranscriptPreview]
}

struct TranscriptPreview: Identifiable {
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

    func loadAsync() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await loadFromCoreDataAsync()
    }

    private func loadFromCoreDataAsync() async {
        let ctx = persistence.newBackgroundContext()

        let summaries: [SessionSummary] = await Task.detached(priority: .userInitiated) { [logger] in
            await ctx.perform { () -> [SessionSummary] in
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
        }.value

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
                    Text("Review your past learning sessions. Each entry shows when you studied, how long, and key metrics.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }

                Section("Understanding Metrics") {
                    HistoryHelpRow(icon: "clock.fill", iconColor: .green, title: "Duration",
                        description: "Total time spent in the session.")
                    HistoryHelpRow(icon: "message.fill", iconColor: .blue, title: "Turns",
                        description: "Number of conversation exchanges. You speak, then the AI responds.")
                    HistoryHelpRow(icon: "dollarsign.circle.fill", iconColor: .orange, title: "Cost",
                        description: "Estimated API usage costs. On-device and self-hosted options are free.")
                    HistoryHelpRow(icon: "bolt.fill", iconColor: .purple, title: "Latency",
                        description: "End-to-end response time. Target: under 500ms median.")
                }

                Section("Target Metrics") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("E2E Latency (median)"); Spacer()
                            Text("< 500ms").foregroundStyle(.green)
                        }
                        HStack {
                            Text("E2E Latency (P99)"); Spacer()
                            Text("< 1000ms").foregroundStyle(.green)
                        }
                        HStack {
                            Text("Cost per hour"); Spacer()
                            Text("< $0.50").foregroundStyle(.green)
                        }
                    }
                    .font(.subheadline)
                }

                Section("Detail View Sections") {
                    HistoryHelpRow(icon: "cpu", iconColor: .indigo, title: "Pipeline Config",
                        description: "Exact models and providers that actually ran, not just what was configured.")
                    HistoryHelpRow(icon: "bolt.fill", iconColor: .yellow, title: "Latency Breakdown",
                        description: "Per-stage median and P99 for STT, LLM, TTS, end-to-end, and TTFA.")
                    HistoryHelpRow(icon: "dollarsign.circle.fill", iconColor: .orange, title: "Cost Breakdown",
                        description: "Per-provider costs with token counts and estimated hourly rate.")
                    HistoryHelpRow(icon: "list.bullet.clipboard", iconColor: .purple, title: "Event Log",
                        description: "Errors, thermal events, barge-ins, and context compressions with timestamps.")
                    HistoryHelpRow(icon: "text.quote", iconColor: .blue, title: "Full Transcript",
                        description: "Complete conversation with real timestamps and session offsets.")
                }

                Section("Exporting Data") {
                    Text("Export your session history as JSON for backup or analysis. Use the menu button to export all sessions. On individual sessions, use the share button to export the full transcript.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
            .navigationTitle("History Help")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct HistoryHelpRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(description)")
    }
}

// MARK: - Preview

#Preview {
    HistoryView()
}

#Preview("History Help") {
    HistoryHelpSheet()
}
