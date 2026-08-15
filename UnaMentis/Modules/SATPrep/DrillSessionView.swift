// UnaMentis - SAT Drill Session View
// Consumes DrillSessionModel (which drives a DrillEngine) and renders the
// voice-first flow with an on-screen fallback: the prompt text is always shown,
// verbal items auto-listen when a voice session is available, and math items
// accept a typed answer through the same engine submitAnswer path. Follows the
// iOS style guide: Dynamic Type, VoiceOver, Reduce Motion, 44pt targets, and
// localizable strings (every learner-facing literal reaches SwiftUI as a
// LocalizedStringKey or a String(localized:)).

import Foundation
import SwiftUI

struct DrillSessionView: View {
    @StateObject private var model: DrillSessionModel
    @Environment(\.dismiss) private var dismiss
    /// Reduce Motion turns the listening indicator's repeating symbol animation
    /// into a single pass (iOS style guide: respect the preference, never gate
    /// meaning on motion).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The large feedback glyphs scale with Dynamic Type instead of pinning to
    /// 64pt.
    @ScaledMetric(relativeTo: .largeTitle) private var resultGlyphSize: CGFloat = 64

    init(kind: SATDrillKind, host: any ModuleHost) {
        _model = StateObject(wrappedValue: DrillSessionModel(
            kind: kind, host: host, moduleId: "sat-prep"
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle(model.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if model.phase != .idle, model.phase != .completed {
                    Button("End") { Task { await model.end(); dismiss() } }
                }
            }
        }
        .task { await model.start() }
        .onDisappear { Task { await model.teardown() } }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            ProgressView(
                value: Double(model.answeredCount),
                total: Double(max(model.totalItems, 1))
            )
            .tint(.indigo)
            HStack {
                Text("Item \(min(model.currentIndex + 1, max(model.totalItems, 1))) of \(model.totalItems)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Label("\(model.streak)", systemImage: "flame.fill")
                    .font(.subheadline)
                    .foregroundStyle(model.streak > 0 ? .orange : .secondary)
                    .accessibilityLabel(Text("Streak \(model.streak)"))
            }
        }
        .padding()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            loadingView
        case .presenting, .awaitingAnswer:
            promptView
        case .feedback:
            feedbackView
        case .completed:
            summaryView
        case .failed(let message):
            failureView(message)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Preparing your drill...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var promptView: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(model.displayText)
                .font(model.isNumericItem ? .system(.title, design: .rounded).weight(.semibold) : .title3)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityLabel(model.promptText)

            if model.isListening {
                Label("Listening...", systemImage: "waveform")
                    .font(.headline)
                    .foregroundStyle(.indigo)
                    .symbolEffect(
                        .variableColor,
                        options: reduceMotion ? .nonRepeating : .repeating
                    )
            }
            if let status = model.statusMessage {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()

            answerControls
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var answerControls: some View {
        VStack(spacing: 12) {
            if model.phase == .awaitingAnswer {
                // On-screen fallback: typed answer, always available (the primary
                // path for math items, the backup for verbal items).
                HStack {
                    answerField
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(model.isNumericItem ? .numbersAndPunctuation : .default)
                        .submitLabel(.done)
                        .onSubmit { Task { await model.submitTypedAnswer() } }
                        .accessibilityLabel("Answer entry")

                    Button {
                        Task { await model.submitTypedAnswer() }
                    } label: {
                        Text("Submit")
                            .frame(minHeight: 44)
                            .padding(.horizontal)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.typedAnswer.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Button {
                    Task { await model.skip() }
                } label: {
                    Text("Skip")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    /// The answer field, branched on the COMPLETE initializer so each
    /// placeholder stays a `LocalizedStringKey`. A ternary inside the
    /// initializer would produce a plain `String` and silently opt the
    /// placeholder out of localization.
    @ViewBuilder
    private var answerField: some View {
        if model.isNumericItem {
            TextField("Type your answer", text: $model.typedAnswer)
        } else {
            TextField("Type your answer (or speak)", text: $model.typedAnswer)
        }
    }

    private var feedbackView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: feedbackIcon)
                .font(.system(size: resultGlyphSize))
                .foregroundStyle(feedbackColor)
                .accessibilityHidden(true)
            Text(feedbackTitle)
                .font(.title2.bold())
            if let answer = model.lastAnswerShown {
                Text("Answer: \(answer)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.next() }
            } label: {
                Text("Next")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(feedbackAccessibilityLabel)
    }

    private var summaryView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: resultGlyphSize))
                .foregroundStyle(.indigo)
                .accessibilityHidden(true)
            Text("Drill complete")
                .font(.title.bold())
            Text("\(model.correctCount) of \(model.answeredCount) correct")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Best streak: \(model.bestStreak)")
                .font(.headline)
                .foregroundStyle(.orange)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            "Drill complete. \(model.correctCount) of \(model.answeredCount) correct. Best streak \(model.bestStreak)."
        ))
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Could not start drill", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Back") { dismiss() }
        }
    }

    // MARK: Feedback styling

    private var feedbackIcon: String {
        switch model.lastCorrect {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "xmark.circle.fill"
        case .none: return "arrow.uturn.right.circle.fill"
        }
    }

    private var feedbackColor: Color {
        switch model.lastCorrect {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary
        }
    }

    /// The on-screen ruling. A `LocalizedStringKey` so `Text` localizes it.
    private var feedbackTitle: LocalizedStringKey {
        switch model.lastCorrect {
        case .some(true): return "Correct"
        case .some(false): return "Not quite"
        case .none: return "Skipped"
        }
    }

    /// The same ruling for VoiceOver. Interpolating the answer key needs a
    /// `String`, so the sentence is localized separately here rather than being
    /// assembled from a `LocalizedStringKey` (which would not localize at all).
    private var feedbackAccessibilityLabel: String {
        let ruling: String
        switch model.lastCorrect {
        case .some(true): ruling = String(localized: "Correct")
        case .some(false): ruling = String(localized: "Not quite")
        case .none: ruling = String(localized: "Skipped")
        }
        guard let answer = model.lastAnswerShown else { return ruling }
        return String(localized: "\(ruling). Answer \(answer)")
    }
}
