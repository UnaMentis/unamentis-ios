// UnaMentis - Quiz Bowl Practice Session View
// The pyramidal tossup practice surface. Renders the view model's engine-driven
// state and offers the buzz interaction: an on-screen buzz button during
// narration (plus the engine's buzz(atCharacterIndex:) via the view model's
// character-index approximation), then voice answer capture.
//
// Modeled on KBOralSessionView's phase-switch renderer. Hands-free first: the
// question reads aloud, the learner buzzes and speaks; touch is a fallback.
//
// Writing style: no em dashes (see .claude/rules/writing-style.md).

import SwiftUI

struct QBPracticeSessionView: View {
    @StateObject var viewModel: QBPracticeSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch viewModel.state {
                case .notStarted: startScreen
                case .readingQuestion: readingScreen
                case .awaitingAnswer: answerScreen
                case .bonus: bonusScreen
                case .showingFeedback: feedbackScreen
                case .completed: summaryScreen
                }
            }
        }
        .navigationTitle("\(viewModel.format.flag) \(viewModel.format.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if viewModel.state != .notStarted && viewModel.state != .completed {
                    Button("End") { Task { await viewModel.end() } }
                }
            }
        }
        .task { await viewModel.prepare() }
        // Backing out mid-tossup must not leave the engine narrating into a
        // voice session nobody owns any more. Teardown stops the engine, ends
        // the registered watch session, and releases the exclusive pipeline.
        .onDisappear { Task { await viewModel.teardown() } }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Tossup \(viewModel.currentQuestionIndex + 1, format: .number) of \(viewModel.totalQuestions, format: .number)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(viewModel.scores.first ?? 0, format: .number) pts")
                .font(.headline.monospacedDigit())
        }
        .padding()
        .background(.thinMaterial)
    }

    // MARK: Start

    private var startScreen: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("\(viewModel.format.name) Tossup Practice")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(viewModel.format.blurb)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            startDetail
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if let error = viewModel.sttError {
                errorBanner(error)
            }
            Spacer()
            Button {
                Task { await viewModel.start() }
            } label: {
                Label("Start Practice", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding(.horizontal)
            .accessibilityLabel("Start \(viewModel.format.name) practice")
        }
        .padding()
    }

    /// The start screen's rules line. A power is promised only where the format
    /// descriptor actually grants one: ACF, IHBB Europe, and UK Schools'
    /// Challenge all declare no power value, so their sessions must not offer it.
    private var startDetail: Text {
        if let power = viewModel.powerPoints {
            return Text("\(viewModel.totalQuestions, format: .number) tossups. Buzz in when you know it. An early correct buzz earns a power worth \(power, format: .number) points.")
        }
        return Text("\(viewModel.totalQuestions, format: .number) tossups. Buzz in when you know it. A correct buzz is worth \(viewModel.correctPoints, format: .number) points.")
    }

    // MARK: Reading (buzz window)

    private var readingScreen: some View {
        VStack(spacing: 20) {
            Spacer()
            questionCard
            ProgressView(value: viewModel.readingProgress)
                .tint(viewModel.inPowerZone ? .yellow : .blue)
                .padding(.horizontal)
            Text(viewModel.inPowerZone ? "Power zone" : "Reading")
                .font(.caption)
                .foregroundStyle(viewModel.inPowerZone ? .orange : .secondary)
            Spacer()
            buzzButton
                .padding(.bottom)
        }
        .padding()
    }

    private var buzzButton: some View {
        Button {
            Task { await viewModel.buzz() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 44))
                // Point values come from the descriptor's scoring table. The
                // hardcoded 15/10 promised a power that formats without one
                // could never pay.
                Text("BUZZ · \(viewModel.buzzPointValue, format: .number)")
                    .font(.caption.bold())
            }
            .frame(width: 130, height: 130)
            .background(viewModel.inPowerZone ? Color.yellow : Color.blue)
            .foregroundStyle(viewModel.inPowerZone ? .black : .white)
            .clipShape(Circle())
        }
        .disabled(!viewModel.canBuzz)
        .opacity(viewModel.canBuzz ? 1 : 0.4)
        .accessibilityLabel("Buzz in")
        .accessibilityHint(Text("Worth \(viewModel.buzzPointValue, format: .number) points"))
    }

    // MARK: Answer

    private var answerScreen: some View {
        VStack(spacing: 20) {
            Spacer()
            listeningIcon
            Text(viewModel.isListening ? "Listening..." : "Tap to speak")
                .font(.title2.weight(.semibold))
            if let error = viewModel.sttError { errorBanner(error) }
            if !viewModel.transcript.isEmpty {
                Text(viewModel.transcript)
                    .font(.title3)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Spacer()
            HStack(spacing: 12) {
                Button {
                    Task {
                        if viewModel.isListening { await viewModel.stopListening() }
                        else { await viewModel.startListening() }
                    }
                } label: {
                    Label(viewModel.isListening ? "Stop" : "Listen",
                          systemImage: viewModel.isListening ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await viewModel.submitAnswer() }
                } label: {
                    Text("Submit")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(viewModel.transcript.isEmpty)
            }
            .padding(.horizontal)
            // A footnote-sized label is well under the 44x44pt minimum touch
            // target, so the label carries the minimum height and the button
            // takes the full width of the row.
            Button {
                Task { await viewModel.skip() }
            } label: {
                Text("Skip this tossup")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
    }

    /// The answer screen's microphone icon. The bounce is gated on Reduce
    /// Motion: a symbol effect that fires on every listening transition is
    /// exactly the motion that preference asks us to drop.
    @ViewBuilder
    private var listeningIcon: some View {
        if reduceMotion {
            listeningIconBase
        } else {
            listeningIconBase.symbolEffect(.bounce, value: viewModel.isListening)
        }
    }

    private var listeningIconBase: some View {
        Image(systemName: viewModel.isListening ? "waveform.circle.fill" : "mic.fill")
            .font(.system(size: 72))
            .foregroundStyle(viewModel.isListening ? Color.green : Color.orange)
            .accessibilityHidden(true)
    }

    // MARK: Bonus

    private var bonusScreen: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Bonus · Part \(viewModel.bonusPartIndex + 1, format: .number) of \(viewModel.bonusPartCount, format: .number)")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(viewModel.bonusPartText)
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            ProgressView().padding(.top)
            Spacer()
        }
        .padding()
    }

    // MARK: Feedback

    private var feedbackScreen: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: viewModel.lastWasCorrect == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(viewModel.lastWasCorrect == true ? .green : .red)
            feedbackTitle
                .font(.title.bold())
                .foregroundStyle(viewModel.lastWasCorrect == true ? .green : .red)
            if viewModel.lastWasCorrect != true, let answer = viewModel.lastCorrectAnswer {
                VStack(spacing: 4) {
                    Text("Correct answer").font(.subheadline).foregroundStyle(.secondary)
                    Text(answer).font(.title2.weight(.semibold))
                }
            }
            Spacer()
            Button {
                Task { await viewModel.next() }
            } label: {
                Label(isLast ? "See Results" : "Next Tossup", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
    }

    /// The awarded points come from the judgment, not from a hardcoded power
    /// value: the engine is the only thing that knows what this format paid.
    private var feedbackTitle: Text {
        guard viewModel.lastWasCorrect == true else { return Text("Incorrect") }
        if viewModel.lastWasPower {
            return Text("Power! +\(viewModel.lastPointsAwarded, format: .number)")
        }
        return Text("Correct! +\(viewModel.lastPointsAwarded, format: .number)")
    }

    private var isLast: Bool {
        viewModel.currentQuestionIndex >= viewModel.totalQuestions - 1
    }

    // MARK: Summary

    private var summaryScreen: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)
                    .padding(.top, 32)
                Text("Session Complete")
                    .font(.title.bold())
                QBMetricsPanel(metrics: viewModel.metrics, totalScore: viewModel.scores.first ?? 0)
                    .padding(.horizontal)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .padding()
            }
        }
    }

    // MARK: Shared

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.currentDomain.isEmpty {
                Text(viewModel.currentDomain.capitalized)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
            Text(viewModel.currentQuestionText)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .padding()
            .background(Color.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
