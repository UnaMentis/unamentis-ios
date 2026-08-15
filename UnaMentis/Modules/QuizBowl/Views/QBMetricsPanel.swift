// UnaMentis - Quiz Bowl Metrics Panel
// A small reusable panel showing the Quiz Bowl metrics the spec calls for
// (QUIZ_BOWL_MODULE_SPEC.md section 6): power rate, points-per-bonus, neg rate,
// and the celerity proxy. Used on both the session summary and the dashboard's
// per-format cards.
//
// Writing style: no em dashes (see .claude/rules/writing-style.md).

import SwiftUI

struct QBMetricsPanel: View {
    let metrics: QBMetrics
    /// Optional total score to show alongside the metrics (session summary).
    var totalScore: Int?

    var body: some View {
        VStack(spacing: 12) {
            if let totalScore {
                metricRow(label: "Total Points", value: QBMetricFormat.count(totalScore))
                Divider()
            }
            metricRow(
                label: "Tossups",
                value: QBMetricFormat.fraction(metrics.tossupsCorrect, of: metrics.tossupsAnswered)
            )
            metricRow(label: "Power Rate", value: QBMetricFormat.percent(metrics.powerRate))
            metricRow(label: "Neg Rate", value: QBMetricFormat.percent(metrics.negRate))
            metricRow(label: "Points / Bonus", value: QBMetricFormat.decimal(metrics.pointsPerBonus))
            metricRow(label: "Buzz Speed (proxy)", value: QBMetricFormat.seconds(metrics.celeritySecondsProxy))
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// `label` is a LocalizedStringKey, not a String: `Text(someString)` renders
    /// verbatim and never looks the copy up, so every row label shipped
    /// untranslated.
    private func metricRow(label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.headline.monospacedDigit())
        }
    }
}

/// A compact per-format stat line for the dashboard picker rows.
struct QBFormatStatLine: View {
    let metrics: QBMetrics

    var body: some View {
        HStack(spacing: 12) {
            stat("Power", value: QBMetricFormat.percent(metrics.powerRate))
            stat("Neg", value: QBMetricFormat.percent(metrics.negRate))
            stat("PPB", value: QBMetricFormat.decimal(metrics.pointsPerBonus))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func stat(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(.primary)
            Text(label)
        }
    }
}

// MARK: - Locale-Aware Metric Formatting

/// The one place Quiz Bowl metrics turn into display strings.
///
/// Every value goes through a Foundation format style, so the learner's locale
/// decides the decimal separator, the digit shapes, and where the percent sign
/// goes. The hand-rolled `"\(Int(rate * 100))%"` and `String(format: "%.1f")`
/// this replaces were correct in en-US and wrong everywhere else, which for a
/// Europe-first module is the wrong way round.
enum QBMetricFormat {
    /// A whole-number percentage, e.g. "50%".
    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// A one-decimal number, e.g. "20.0".
    static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// A plain integer count.
    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// A "correct of answered" pair, e.g. "3/5".
    static func fraction(_ numerator: Int, of denominator: Int) -> String {
        "\(count(numerator))/\(count(denominator))"
    }

    /// A duration in seconds with the locale's unit form, or a placeholder when
    /// there is nothing to average yet.
    static func seconds(_ value: Double?) -> String {
        guard let value else { return "--" }
        return Measurement(value: value, unit: UnitDuration.seconds)
            .formatted(
                .measurement(
                    width: .narrow,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(1))
                )
            )
    }
}
