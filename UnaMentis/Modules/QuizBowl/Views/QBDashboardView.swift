// UnaMentis - Quiz Bowl Dashboard
// The module's root view: a format picker (NAQT, ACF, and the European IHBB and
// UK formats, each with a flag and name) with per-format stats (power rate,
// points-per-bonus, neg rate, and the celerity proxy), launching pyramidal
// tossup practice.
//
// The dashboard reaches host services through the injected ModuleHost (captured
// in QuizBowlRuntime at initialize(host:), falling back to the catalog host).
// It loads each format's bundled starter pack through the host ContentStore and
// its running stats through the module KV store.
//
// Writing style: no em dashes (see .claude/rules/writing-style.md).

import SwiftUI

struct QBDashboardView: View {
    @State private var statsByFormat: [String: QBMetrics] = [:]
    @State private var loadError: String?

    var body: some View {
        List {
            Section {
                ForEach(QBFormat.all) { format in
                    NavigationLink {
                        QBPracticeLauncher(format: format)
                    } label: {
                        formatRow(format)
                    }
                }
            } header: {
                Text("Choose a format")
            } footer: {
                Text("Buzz in on pyramidal tossups. An early correct buzz earns a power; a wrong interrupt negs.")
            }

            if let loadError {
                Section {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Quiz Bowl")
        .task { await loadStats() }
    }

    private func formatRow(_ format: QBFormat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(format.flag)
                    .font(.title2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(format.name).font(.headline)
                    Text(format.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if let metrics = statsByFormat[format.id], metrics.tossupsAnswered > 0 {
                QBFormatStatLine(metrics: metrics)
                    .padding(.leading, 34)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: format))
    }

    /// The row's spoken label. It carries the same per-format stats the stat
    /// line shows: `.combine` cannot reach them once the label is overridden, so
    /// a VoiceOver user was told the format name and blurb and nothing else,
    /// while a sighted user saw power rate, neg rate, and points per bonus.
    private func accessibilityLabel(for format: QBFormat) -> Text {
        guard let metrics = statsByFormat[format.id], metrics.tossupsAnswered > 0 else {
            return Text("\(format.name). \(format.blurb)")
        }
        return Text("""
            \(format.name). \(format.blurb) \
            Power rate \(QBMetricFormat.percent(metrics.powerRate)), \
            neg rate \(QBMetricFormat.percent(metrics.negRate)), \
            \(QBMetricFormat.decimal(metrics.pointsPerBonus)) points per bonus.
            """)
    }

    @MainActor
    private func loadStats() async {
        let host = await QuizBowlRuntime.shared.host ?? ModuleCatalog.shared.host
        let store = QBStatsStore(progress: host.progress)
        var results: [String: QBMetrics] = [:]
        for format in QBFormat.all {
            results[format.id] = await store.stats(for: format.id).metrics
        }
        statsByFormat = results
    }
}

// MARK: - Practice Launcher

/// Loads a format's content pack and presents the practice session. Kept as a
/// small launcher so pack loading (which is async and can fail) happens on entry,
/// not in the dashboard list.
struct QBPracticeLauncher: View {
    let format: QBFormat

    @State private var viewModel: QBPracticeSessionViewModel?
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let viewModel {
                QBPracticeSessionView(viewModel: viewModel)
            } else if isLoading {
                ProgressView("Loading questions...")
            } else {
                ContentUnavailableView(
                    "Questions Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError ?? "This format's questions could not be loaded.")
                )
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        guard viewModel == nil else { return }
        let host = await QuizBowlRuntime.shared.host ?? ModuleCatalog.shared.host
        do {
            let descriptor = try QuizMatchFormatDescriptor.load(named: format.id)
            let items = try await QBContentProvider.loadItems(
                packId: format.packId, content: host.content
            )
            guard !items.isEmpty else {
                loadError = "The \(format.name) starter pack is empty."
                isLoading = false
                return
            }
            // The descriptor's declared oral question count is the session
            // length, and the selection is shuffled. Running the whole pack in
            // file order made every session both longer than the format says
            // (qb-naqt declares 24 and ran 33) and identical to the last one.
            let selected = QBSessionPlanner.selectItems(from: items, descriptor: descriptor)
            viewModel = QBPracticeSessionViewModel(format: format, questions: selected, host: host)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
