// UnaMentis - SAT Dashboard
// The module's root surface: an honest framing line, the two drill modes, and
// SAT domain cards showing current mastery read from the host ProgressStore
// (MODULE_SDK_SPEC.md section 5.4). Follows the iOS style guide: Dynamic Type,
// VoiceOver labels, 44pt touch targets, localizable strings.

import Foundation
import SwiftUI

// MARK: - Dashboard

struct SATDashboardView: View {
    @StateObject private var model = SATDashboardModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                framingLine
                drillModes
                domainSection
            }
            .padding()
        }
        .navigationTitle("SAT Prep")
        .task { await model.load() }
    }

    // MARK: Framing

    private var framingLine: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.title2)
                .foregroundStyle(.indigo)
                .accessibilityHidden(true)
            Text("Voice-assisted: about a third of SAT prep works great by voice; the rest needs your eyes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: Drill Modes

    private var drillModes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drills")
                .font(.headline)
            ForEach(SATDrillKind.allCases) { kind in
                NavigationLink {
                    DrillSessionView(kind: kind, host: model.host)
                } label: {
                    drillModeCard(kind)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func drillModeCard(_ kind: SATDrillKind) -> some View {
        HStack(spacing: 16) {
            Image(systemName: kind == .vocab ? "text.book.closed" : "function")
                // Symbol name, not user-facing text: no localization needed.
                .font(.title)
                .foregroundStyle(.indigo)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(Self.drillModeDescription(kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding()
        .frame(minHeight: 44)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(kind.title) drill"))
        .accessibilityHint(Text("Starts a ten item \(kind.title) drill"))
    }

    /// Branch on the complete value so each description stays a
    /// `LocalizedStringKey`: a ternary inside `Text(...)` collapses to a plain
    /// `String` and never reaches the string catalog.
    private static func drillModeDescription(_ kind: SATDrillKind) -> LocalizedStringKey {
        switch kind {
        case .vocab: return "Say the meaning of a word in context. 10 items."
        case .math: return "Solve a problem in your head. Speak or type. 10 items."
        }
    }

    // MARK: Domain Mastery

    private var domainSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Domains")
                .font(.headline)
            if model.domains.isEmpty {
                Text("Practice a drill to start building mastery.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.domains) { domain in
                    domainCard(domain)
                }
            }
        }
    }

    private func domainCard(_ domain: SATDomainMastery) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(domain.displayName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(domain.mastery))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: domain.mastery, total: 100)
                .tint(.indigo)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(domain.displayName), \(Int(domain.mastery)) percent mastery"))
    }
}

// MARK: - Dashboard Model

/// Reads domain mastery from the host ProgressStore for the dashboard cards.
@MainActor
final class SATDashboardModel: ObservableObject {
    @Published private(set) var domains: [SATDomainMastery] = []

    let host: any ModuleHost

    init() {
        // The catalog builds the shared host; the dashboard reads through it.
        self.host = ModuleCatalog.shared.host
    }

    /// The SAT content domains shown, in SAT_MODULE.md order. The tag is the
    /// proficiency key (never translated); the name is learner-facing, so it is
    /// localized here, computed rather than cached so a locale change is picked
    /// up on the next read.
    private static var shownDomains: [(tag: String, name: String)] {
        [
            ("craft-and-structure", String(localized: "Craft & Structure")),
            ("information-and-ideas", String(localized: "Information & Ideas")),
            ("standard-english-conventions", String(localized: "Standard English Conventions")),
            ("expression-of-ideas", String(localized: "Expression of Ideas")),
            ("algebra", String(localized: "Algebra")),
            ("advanced-math", String(localized: "Advanced Math")),
            ("problem-solving-data", String(localized: "Problem Solving & Data")),
            ("geometry-trig", String(localized: "Geometry & Trigonometry"))
        ]
    }

    func load() async {
        var result: [SATDomainMastery] = []
        for entry in Self.shownDomains {
            let prof = await host.progress.proficiency(for: StandardDomain(entry.tag))
            if prof.observationCount > 0 {
                result.append(SATDomainMastery(
                    id: entry.tag, displayName: entry.name, mastery: prof.mastery
                ))
            }
        }
        domains = result
    }
}

/// One domain's mastery for the dashboard.
struct SATDomainMastery: Identifiable, Equatable {
    let id: String
    let displayName: String
    let mastery: Double
}

// MARK: - Compact Dashboard Card

/// The compact card shown in the Learning tab's module list.
struct SATPrepDashboardCard: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("SAT Prep")
                    .font(.headline)
                Text("Voice-assisted vocab & mental math")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("SAT Prep module")
    }
}
