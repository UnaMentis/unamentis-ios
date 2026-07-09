//
//  KBOralSessionView.swift
//  UnaMentis
//
//  Oral round practice view for Knowledge Bowl with voice interaction
//

import AVFoundation
import Speech
import SwiftUI

// MARK: - Oral Session View

struct KBOralSessionView: View {
    @ObservedObject var viewModel: KBOralSessionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header with progress
            sessionHeader

            // Main content
            Group {
                switch viewModel.state {
                case .notStarted:
                    startScreen
                case .readingQuestion:
                    questionReadingScreen
                case .conferenceTime:
                    conferenceScreen
                case .listeningForAnswer:
                    listeningScreen
                case .showingFeedback:
                    feedbackScreen
                case .completed:
                    summaryScreen
                }
            }
        }
        .background(Color.kbBgPrimary)
        .navigationBarBackButtonHidden(viewModel.state != .notStarted && viewModel.state != .completed)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if viewModel.state != .notStarted && viewModel.state != .completed {
                    Button("End") {
                        Task { await viewModel.endSession() }
                    }
                    .foregroundColor(.kbFocusArea)
                }
            }
        }
        .onAppear {
            Task {
                await viewModel.prepareServices()
            }
        }
    }

    // MARK: - Session Header

    private var sessionHeader: some View {
        VStack(spacing: 8) {
            // Progress bar
            progressBar

            // Question counter and score
            HStack {
                Text("Question \(viewModel.currentQuestionIndex + 1) of \(viewModel.questions.count)")
                    .font(.subheadline)
                    .foregroundColor(.kbTextSecondary)

                Spacer()

                Text("\(viewModel.session.correctCount) correct")
                    .font(.subheadline)
                    .foregroundColor(.kbMastered)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 12)
        .background(Color.kbBgSecondary)
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.kbBorder)
                    .frame(height: 4)

                Rectangle()
                    .fill(Color.kbMastered)
                    .frame(width: geometry.size.width * viewModel.progress, height: 4)
                    .animation(.easeInOut(duration: 0.3), value: viewModel.progress)
            }
        }
        .frame(height: 4)
        .padding(.horizontal)
    }

    // MARK: - Start Screen

    private var startScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "mic.fill")
                .font(.system(size: 60))
                .foregroundColor(.kbMastered)

            Text("Oral Round Practice")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.kbTextPrimary)

            Text("Questions will be read aloud. You'll have time to confer, then speak your answer.")
                .font(.body)
                .foregroundColor(.kbTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                configRow(icon: "number", label: "Questions", value: "\(viewModel.questions.count)")
                HStack {
                    configRow(icon: "timer", label: "Conference Time", value: "\(Int(viewModel.regionalConfig.conferenceTime))s")
                    InfoButton(
                        title: "Conference Time",
                        content: KBHelpContent.TrainingModes.oralConference
                    )
                }
                configRow(icon: "mappin", label: "Region", value: viewModel.regionalConfig.region.displayName)
                configRow(icon: "star", label: "Points", value: "\(viewModel.regionalConfig.oralPointsPerCorrect) per correct")
                HStack {
                    configRow(
                        icon: "person.2",
                        label: "Verbal Conferring",
                        value: viewModel.regionalConfig.verbalConferringAllowed ? "Allowed" : "Silent Only"
                    )
                    InfoButton(
                        title: "Conference Rules",
                        content: KBHelpContent.Regional.conferenceDifferences
                    )
                }
            }
            .padding()
            .background(Color.kbBgSecondary)
            .cornerRadius(12)

            Spacer()

            // Permission status
            if !viewModel.hasPermissions {
                Text("Microphone and speech recognition permissions required")
                    .font(.caption)
                    .foregroundColor(.kbFocusArea)
            }

            // Loading indicator while prewarming TTS
            if viewModel.isPrewarming {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                    Text("Preparing voice engine...")
                        .font(.caption)
                        .foregroundColor(.kbTextSecondary)
                }
                .padding(.bottom, 8)
            }

            Button(action: {
                Task { await viewModel.startSession() }
            }) {
                Text(viewModel.isPrewarming ? "Preparing..." : "Start Practice")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(viewModel.isPrewarming ? Color.gray : Color.kbMastered)
                    .cornerRadius(12)
            }
            .disabled(viewModel.isPrewarming)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
    }

    private func configRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.kbTextSecondary)
                .frame(width: 24)
            Text(label)
                .foregroundColor(.kbTextSecondary)
            Spacer()
            Text(value)
                .foregroundColor(.kbTextPrimary)
                .fontWeight(.medium)
        }
    }

    // MARK: - Question Reading Screen

    private var questionReadingScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            // Speaking indicator
            VStack(spacing: 16) {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.kbIntermediate)
                    .symbolEffect(.variableColor.iterative, options: .repeating)

                Text("Reading Question...")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.kbTextPrimary)
            }

            // Question card
            if let question = viewModel.currentQuestion {
                questionCard(question)
            }

            // TTS progress
            ProgressView(value: viewModel.ttsProgress)
                .progressViewStyle(LinearProgressViewStyle(tint: .kbIntermediate))
                .padding(.horizontal)

            Spacer()
        }
        .padding()
    }

    // MARK: - Conference Screen

    private var conferenceScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            // Conference timer
            ZStack {
                Circle()
                    .stroke(Color.kbBorder, lineWidth: 8)
                    .frame(width: 150, height: 150)

                Circle()
                    .trim(from: 0, to: viewModel.conferenceProgress)
                    .stroke(
                        viewModel.conferenceTimeRemaining < 5 ? Color.kbFocusArea : Color.kbMastered,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 150, height: 150)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: viewModel.conferenceProgress)

                VStack {
                    Text("\(Int(viewModel.conferenceTimeRemaining))")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(viewModel.conferenceTimeRemaining < 5 ? .kbFocusArea : .kbTextPrimary)

                    Text("seconds")
                        .font(.caption)
                        .foregroundColor(.kbTextSecondary)
                }
            }

            HStack {
                Text("Conference Time")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.kbTextPrimary)

                InfoButton(
                    title: "Conference",
                    content: KBHelpContent.TrainingModes.oralConference
                )
            }

            Text(viewModel.regionalConfig.verbalConferringAllowed
                 ? "Discuss with your team"
                 : "Silent conferring only")
                .font(.body)
                .foregroundColor(.kbTextSecondary)

            // Question card (collapsed)
            if let question = viewModel.currentQuestion {
                questionCardCompact(question)
            }

            Spacer()

            // Skip conference button
            Button(action: {
                Task { await viewModel.skipConference() }
            }) {
                Text("Ready to Answer")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.kbIntermediate)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
    }

    // MARK: - Listening Screen

    private var listeningScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            // Listening indicator
            VStack(spacing: 16) {
                Image(systemName: viewModel.isListening ? "waveform.circle.fill" : "mic.fill")
                    .font(.system(size: 80))
                    .foregroundColor(viewModel.isListening ? .kbMastered : .kbIntermediate)
                    .symbolEffect(.bounce, value: viewModel.isListening)

                HStack {
                    Text(viewModel.isListening ? "Listening..." : "Tap to Speak")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.kbTextPrimary)

                    InfoButton(
                        title: "Voice Input",
                        content: KBHelpContent.TrainingModes.oralVoiceInput
                    )
                }
            }

            // Error display
            if let error = viewModel.sttError {
                Text(error)
                    .font(.subheadline)
                    .foregroundColor(.kbFocusArea)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(Color.kbFocusArea.opacity(0.1))
                    .cornerRadius(8)
            }

            // Transcript display
            if !viewModel.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Your Answer")
                            .font(.caption)
                            .foregroundColor(.kbTextSecondary)
                        InfoButton(
                            title: "Transcript",
                            content: KBHelpContent.TrainingModes.oralTranscript
                        )
                    }
                    Text(viewModel.transcript)
                        .font(.title3)
                        .foregroundColor(.kbTextPrimary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.kbBgSecondary)
                .cornerRadius(12)
            }

            // Question card (compact)
            if let question = viewModel.currentQuestion {
                questionCardCompact(question)
            }

            Spacer()

            // Control buttons
            HStack(spacing: 16) {
                Button(action: {
                    Task { await viewModel.toggleListening() }
                }) {
                    HStack {
                        Image(systemName: viewModel.isListening ? "stop.fill" : "mic.fill")
                        Text(viewModel.isListening ? "Stop" : "Start Listening")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(viewModel.isListening ? Color.kbFocusArea : Color.kbMastered)
                    .cornerRadius(12)
                }

                if !viewModel.transcript.isEmpty && !viewModel.isListening {
                    Button(action: {
                        Task { await viewModel.submitAnswer() }
                    }) {
                        Text("Submit")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.kbIntermediate)
                            .cornerRadius(12)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
    }

    // MARK: - Feedback Screen

    private var feedbackScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            // Result icon
            Image(systemName: viewModel.lastAnswerCorrect == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(viewModel.lastAnswerCorrect == true ? .kbMastered : .kbFocusArea)

            Text(viewModel.lastAnswerCorrect == true ? "Correct!" : "Incorrect")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(viewModel.lastAnswerCorrect == true ? .kbMastered : .kbFocusArea)

            // Show correct answer if wrong
            if viewModel.lastAnswerCorrect != true, let question = viewModel.currentQuestion {
                VStack(spacing: 8) {
                    Text("Correct answer:")
                        .font(.subheadline)
                        .foregroundColor(.kbTextSecondary)

                    Text(question.answer.primary)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.kbTextPrimary)
                }
                .padding()
                .background(Color.kbBgSecondary)
                .cornerRadius(12)
            }

            // User's answer
            if !viewModel.transcript.isEmpty {
                VStack(spacing: 8) {
                    Text("Your answer:")
                        .font(.subheadline)
                        .foregroundColor(.kbTextSecondary)

                    Text(viewModel.transcript)
                        .font(.body)
                        .foregroundColor(.kbTextSecondary)
                }
            }

            Spacer()

            Button(action: {
                Task { await viewModel.nextQuestion() }
            }) {
                HStack {
                    Text(viewModel.isLastQuestion ? "See Results" : "Next Question")
                    Image(systemName: "arrow.right")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.kbMastered)
                .cornerRadius(12)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .padding()
    }

    // MARK: - Summary Screen

    private var summaryScreen: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Result icon
                Image(systemName: viewModel.session.accuracy >= 0.7 ? "trophy.fill" : "flag.checkered")
                    .font(.system(size: 60))
                    .foregroundColor(viewModel.session.accuracy >= 0.7 ? .kbGold : .kbIntermediate)
                    .padding(.top, 40)

                // Title
                Text("Session Complete!")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.kbTextPrimary)

                // Score card
                VStack(spacing: 16) {
                    summaryRow(label: "Score", value: "\(viewModel.session.correctCount)/\(viewModel.session.attempts.count)")
                    summaryRow(label: "Accuracy", value: String(format: "%.0f%%", viewModel.session.accuracy * 100))
                    summaryRow(label: "Points", value: "\(viewModel.session.totalPoints)")
                    summaryRow(label: "Time", value: formatTime(viewModel.session.duration))
                }
                .padding()
                .background(Color.kbBgSecondary)
                .cornerRadius(12)
                .padding(.horizontal)

                // Accuracy meter
                accuracyMeter

                Spacer()

                // Done button
                Button(action: {
                    dismiss()
                }) {
                    Text("Done")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.kbMastered)
                        .cornerRadius(12)
                }
                .padding()
            }
        }
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.kbTextSecondary)
            Spacer()
            Text(value)
                .font(.headline)
                .foregroundColor(.kbTextPrimary)
        }
    }

    private var accuracyMeter: some View {
        VStack(spacing: 8) {
            Text("Accuracy")
                .font(.headline)
                .foregroundColor(.kbTextPrimary)

            ZStack {
                Circle()
                    .stroke(Color.kbBorder, lineWidth: 12)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: viewModel.session.accuracy)
                    .stroke(
                        viewModel.session.accuracy >= 0.7 ? Color.kbMastered : Color.kbBeginner,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 1), value: viewModel.session.accuracy)

                Text(String(format: "%.0f%%", viewModel.session.accuracy * 100))
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.kbTextPrimary)
            }
        }
        .padding()
    }

    // MARK: - Question Cards

    private func questionCard(_ question: KBQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Domain indicator
            HStack {
                Image(systemName: question.domain.icon)
                    .foregroundColor(question.domain.color)
                Text(question.domain.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(question.domain.color)

                Spacer()

                Text(question.difficulty.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.kbBgSecondary)
                    .cornerRadius(4)
            }

            // Question text
            Text(question.text)
                .font(.title3)
                .foregroundColor(.kbTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(Color.kbBgSecondary)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(question.domain.color.opacity(0.3), lineWidth: 2)
        )
    }

    private func questionCardCompact(_ question: KBQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: question.domain.icon)
                    .foregroundColor(question.domain.color)
                Text(question.domain.displayName)
                    .font(.caption)
                    .foregroundColor(question.domain.color)

                Spacer()
            }

            Text(question.text)
                .font(.body)
                .foregroundColor(.kbTextSecondary)
                .lineLimit(2)
        }
        .padding()
        .background(Color.kbBgSecondary.opacity(0.5))
        .cornerRadius(8)
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Oral Session View Model

/// Knowledge Bowl oral practice, rendered over the generic QuizMatchEngine
/// (MODULE_SDK_SPEC.md section 6.1, migration Phase 5).
///
/// The view model no longer runs the session state machine: the engine owns
/// question presentation, conference timing, answer capture, evaluation,
/// scoring, and progress/telemetry emission, driven by KB's format descriptor
/// (KBQuizMatchAdapter). This class renders engine events into published UI
/// state, forwards user intents (taps and voice commands) to engine commands,
/// keeps KB's own on-disk session history (KBSessionManager), and owns the
/// module-side concerns: voice pipeline acquisition, permissions, hands-free
/// audio feedback, and watch session registration.
@MainActor
final class KBOralSessionViewModel: ObservableObject {
    // MARK: - Published State

    @Published var session: KBSession
    @Published var questions: [KBQuestion]
    @Published var currentQuestionIndex: Int = 0
    @Published var state: KBOralSessionState = .notStarted

    // TTS State
    @Published var ttsProgress: Float = 0
    @Published var isSpeaking = false
    @Published var isPrewarming = true  // Track TTS prewarm status

    // STT State
    @Published var transcript = ""
    @Published var isListening = false
    @Published var sttError: String?

    // Conference State
    @Published var conferenceTimeRemaining: TimeInterval = 0
    @Published var conferenceProgress: Double = 1.0

    // Answer State
    @Published var lastAnswerCorrect: Bool?
    @Published var hasPermissions = false

    // Voice Command State (Hands-Free First)
    @Published var voiceCommandFeedback: String = ""
    @Published var lastRecognizedCommand: VoiceCommand?

    // MARK: - Services

    /// The host voice pipeline session (MODULE_SDK_SPEC.md section 5.1,
    /// capability "voice.session/1"). Knowledge Bowl owns no STT, TTS, VAD,
    /// or audio engine; the view model acquires the exclusive VoiceSession
    /// (with descriptor-derived endpointing) and hands it to the engine.
    private var voice: (any VoiceSession)?

    /// The generic quiz-match engine driving this session. Constructed at
    /// session start from KB's format descriptor and the selected questions.
    private var engine: QuizMatchEngine?

    private let sessionManager = KBSessionManager()

    /// The host-registered session (MODULE_SDK_SPEC.md section 5.9). Registering
    /// makes this KB oral session appear on the watch (title, progress, elapsed)
    /// with working pause/stop, feeds module telemetry, and routes session
    /// errors into the session error-log drill-down. Nil until the session
    /// starts.
    private var registeredSession: RegisteredSession?

    // Voice-First Services (see docs/design/HANDS_FREE_FIRST_DESIGN.md)
    private let commandRecognizer = VoiceCommandRecognizer()
    private let voiceFeedback = VoiceActivityFeedback()

    /// The strictness profile KB evaluates oral answers at. Preserves the prior
    /// behavior of the module-local validator, which ran at `.standard` (the
    /// KBAnswerValidator default) regardless of region. The regional strictness
    /// on KBRegionalConfig was never applied at this call site; wiring it in is a
    /// deliberate follow-up, tracked separately, not part of this behavior-
    /// preserving lift.
    private let evaluationStrictness: KBValidationStrictness = .standard

    // MARK: - Configuration

    let config: KBSessionConfig
    let regionalConfig: KBRegionalConfig

    // MARK: - Tasks

    private var engineEventTask: Task<Void, Never>?
    private var voiceEventTask: Task<Void, Never>?
    private var voiceCommandTask: Task<Void, Never>?

    /// Guard so watch stop, user End, and engine match-end teardown compose.
    private var hasFinished = false

    // MARK: - Computed Properties

    var currentQuestion: KBQuestion? {
        guard currentQuestionIndex < questions.count else { return nil }
        return questions[currentQuestionIndex]
    }

    var progress: Double {
        guard !questions.isEmpty else { return 0 }
        return Double(currentQuestionIndex) / Double(questions.count)
    }

    var isLastQuestion: Bool {
        currentQuestionIndex >= questions.count - 1
    }

    // MARK: - Initialization

    init(questions: [KBQuestion], config: KBSessionConfig) {
        self.questions = questions
        self.config = config
        self.regionalConfig = config.region.config
        self.session = KBSession(config: config)
        self.conferenceTimeRemaining = config.region.config.conferenceTime

        // Register session with manager for lifecycle management
        Task {
            _ = await sessionManager.startSession(questions: questions, config: config)
        }
    }

    deinit {
        // Safety net: if the view model goes away without endSession (view
        // dismissed mid-session), hand the exclusive voice pipeline back.
        let session = voice
        Task {
            await session?.release()
        }
    }

    // MARK: - Service Setup

    func prepareServices() async {
        let prepareStart = CFAbsoluteTimeGetCurrent()
        NSLog("⏱️ [KBOralSession] prepareServices() START")

        isPrewarming = true

        // Acquire the exclusive host voice session, configured from KB's
        // format descriptor (endpointing, conference, buzz mode). Acquisition
        // prewarms the configured on-device TTS so the first question reads
        // without delay.
        if voice == nil {
            do {
                let descriptor = KBQuizMatchAdapter.descriptor(for: regionalConfig)
                voice = try await ModuleCatalog.shared.host.voice.acquire(
                    config: descriptor.voicePipelineConfig()
                )
                startVoiceEventMonitoring()
            } catch {
                NSLog("[KBOralSession] Voice pipeline unavailable: \(error.localizedDescription)")
                sttError = error.localizedDescription
            }
        }

        // Check if STT is available
        hasPermissions = AppleSpeechSTTService.isAvailable

        isPrewarming = false

        let prepareTime = (CFAbsoluteTimeGetCurrent() - prepareStart) * 1000
        NSLog("⏱️ [KBOralSession] prepareServices() COMPLETE - took %.1fms", prepareTime)
    }

    /// Mirror real-time voice events (partial transcripts) into published
    /// state. The engine does not consume `voice.events` (single-consumer
    /// stream); live partials remain a view-model concern.
    private func startVoiceEventMonitoring() {
        voiceEventTask?.cancel()
        guard let voice else { return }
        voiceEventTask = Task { @MainActor [weak self] in
            for await event in voice.events {
                guard let self else { break }
                if case .partialTranscript(let text) = event, self.isListening {
                    self.transcript = text
                }
            }
        }
    }

    private func requestPermissionsIfNeeded() async -> Bool {
        print("[KB] Oral session: requesting speech authorization...")
        let authStatus = await AppleSpeechSTTService.requestAuthorization()
        let speechAuth = authStatus == .authorized
        print("[KB] Oral session: speech auth = \(speechAuth)")

        print("[KB] Oral session: requesting microphone access...")
        let micAuth = await AVAudioApplication.requestRecordPermission()
        print("[KB] Oral session: mic auth = \(micAuth)")

        hasPermissions = speechAuth && micAuth
        print("[KB] Oral session: hasPermissions = \(hasPermissions)")
        return hasPermissions
    }

    // MARK: - Engine Setup

    /// Build the quiz-match engine for this session: KB's regional rules as a
    /// format descriptor, the selected questions as engine questions, and the
    /// host services the engine emits progress and telemetry through.
    private func makeEngine() -> QuizMatchEngine {
        let descriptor = KBQuizMatchAdapter.descriptor(for: regionalConfig)
        let strictness = evaluationStrictness
        let engineQuestions = questions.map {
            KBQuizMatchAdapter.engineQuestion(from: $0, strictness: strictness)
        }
        let host = ModuleCatalog.shared.host
        let context = QuizMatchHostContext(
            moduleId: KBProgressAdapter.moduleID,
            evaluation: host.evaluation,
            progress: host.progress,
            telemetry: host.telemetry
        )
        return QuizMatchEngine(
            descriptor: descriptor,
            options: QuizMatchSessionOptions(questionCount: engineQuestions.count),
            host: context,
            provider: { index in
                index < engineQuestions.count ? engineQuestions[index] : nil
            }
        )
    }

    /// Render engine events into published state and hands-free feedback.
    private func startEngineEventMonitoring(_ engine: QuizMatchEngine) {
        engineEventTask?.cancel()
        engineEventTask = Task { @MainActor [weak self] in
            for await event in engine.events {
                guard let self else { break }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: QuizMatchEvent) async {
        switch event {
        case .matchStarted:
            break

        case .questionPresented(let index, _):
            currentQuestionIndex = index
            if index > 0 {
                // Announce question number (Hands-Free First)
                voiceFeedback.announceNextQuestion(number: index + 1, total: questions.count)
            }
            state = .readingQuestion
            isSpeaking = true
            ttsProgress = 0.1
            await TTFAInstrumentation.shared.markActivation(.kbOral)

        case .questionReadingFinished:
            isSpeaking = false
            ttsProgress = 1.0

        case .speakFailed(let message):
            // Surface synthesis failures instead of silently playing nothing.
            NSLog("[KBOralSession] TTS failed: \(message)")
            sttError = message
            ttsProgress = 0
            isSpeaking = false
            // Feed the error into the session error-log drill-down (section 5.9).
            registeredSession?.reportError(KBOralSessionError.narrationFailed(message))

        case .conferenceStarted(let seconds):
            conferenceTimeRemaining = seconds
            conferenceProgress = 1.0
            state = .conferenceTime
            // Announce conference time start (Hands-Free First)
            voiceFeedback.announceCountdownStart(seconds: Int(seconds), context: "Conference time")

        case .conferenceTick(let remaining, let progress):
            conferenceTimeRemaining = remaining
            conferenceProgress = progress

        case .conferenceMilestone(let secondsRemaining):
            voiceFeedback.announceCountdownMilestone(seconds: secondsRemaining)

        case .conferenceCountdownTick:
            voiceFeedback.playCountdownTick()

        case .conferenceEnded(let skipped):
            if !skipped {
                voiceFeedback.announceCountdownComplete(context: "Ready to answer")
            }

        case .answerWindowOpened:
            // Mirrors the old startListeningPhase: fresh transcript, then the
            // listening screen (auto-listen follows from the engine).
            transcript = ""
            state = .listeningForAnswer

        case .listeningStarted:
            sttError = nil
            isListening = true

        case .listeningStopped:
            // User stopped listening; keep the partial transcript.
            isListening = false

        case .answerCaptured(let text):
            transcript = text
            isListening = false

        case .listenFailed(let message):
            print("[KB] STT Error: \(message)")
            isListening = false
            sttError = "Speech recognition unavailable. Please try on a physical device."
            // Feed into the session error-log drill-down (section 5.9).
            registeredSession?.reportError(KBOralSessionError.listenFailed(message))

        case .evaluated(_, let judgment):
            recordEvaluatedAttempt(judgment)

        case .answerSkipped:
            // Marked as skipped by voice command; no attempt is recorded.
            lastAnswerCorrect = false
            state = .showingFeedback
            voiceFeedback.announceIncorrect(correctAnswer: currentQuestion?.answer.allValidAnswers.first)

        case .scoreChanged, .reboundOffered,
             .bonusStarted, .bonusPartPresented, .bonusPartEvaluated, .bonusCompleted,
             .paused, .resumed:
            // Solo KB practice: session totals derive from recorded attempts;
            // rebound/bonus mechanics are not part of this format's flow.
            break

        case .matchEnded:
            finishSession()
        }
    }

    /// Fold an engine judgment into KB's session model and on-disk history.
    /// The engine already emitted the host AttemptRecord, the mastery
    /// observation, and the module.attempt telemetry event; what remains here
    /// is KB-shaped: the KBQuestionAttempt for stats screens and store.
    private func recordEvaluatedAttempt(_ judgment: QuizMatchJudgment) {
        guard let question = currentQuestion else { return }
        let result = KBEvaluationBridge.kbResult(from: judgment.evaluation)

        let attempt = KBQuestionAttempt(
            questionId: question.id,
            domain: question.domain,
            userAnswer: judgment.answerText,
            responseTime: Double(judgment.responseTimeMs) / 1000,
            wasCorrect: result.isCorrect,
            pointsEarned: judgment.pointsAwarded,
            roundType: .oral,
            matchType: result.matchType
        )

        // Record locally for immediate UI updates
        session.attempts.append(attempt)
        lastAnswerCorrect = result.isCorrect

        // Also record with session manager for KB's own on-disk history.
        Task {
            await sessionManager.recordAttempt(attempt)
        }

        // Push updated progress to the watch.
        updateRegisteredProgress()

        // Audio and haptic feedback (Hands-Free First)
        if result.isCorrect {
            voiceFeedback.announceCorrect()
        } else {
            voiceFeedback.announceIncorrect(correctAnswer: question.answer.allValidAnswers.first)
        }

        state = .showingFeedback
    }

    // MARK: - Session Control

    func startSession() async {
        let sessionStart = CFAbsoluteTimeGetCurrent()
        NSLog("⏱️ [KBOralSession] startSession() START - USER TAPPED START")

        // Request permissions before starting
        let hasPerms = await requestPermissionsIfNeeded()
        let permTime = (CFAbsoluteTimeGetCurrent() - sessionStart) * 1000
        NSLog("⏱️ [KBOralSession] startSession() - permissions took %.1fms, result = \(hasPerms)", permTime)

        guard hasPerms else {
            NSLog("⏱️ [KBOralSession] startSession() - permissions not granted, returning")
            return
        }

        // Register as a first-class app session so this oral practice shows on
        // the watch with working pause/stop and feeds telemetry + the error log
        // (MODULE_SDK_SPEC.md section 5.9).
        beginRegisteredSession()

        // Start voice command monitoring (Hands-Free First)
        startVoiceCommandMonitoring()
        voiceFeedback.announceActivityStarted("Oral Practice")

        // Hand the acquired voice session to the engine and start the match.
        let engine = makeEngine()
        self.engine = engine
        startEngineEventMonitoring(engine)
        await engine.start(voice: voice)

        let totalTime = (CFAbsoluteTimeGetCurrent() - sessionStart) * 1000
        NSLog("⏱️ [KBOralSession] startSession() COMPLETE - took %.1fms", totalTime)
    }

    /// Register this oral session with the host so it becomes a first-class app
    /// session on the watch and in telemetry (MODULE_SDK_SPEC.md section 5.9).
    /// Watch pause/stop route back into the existing session controls.
    private func beginRegisteredSession() {
        guard registeredSession == nil else { return }
        let descriptor = ModuleSessionDescriptor(
            module: KBProgressAdapter.moduleID,
            title: "Knowledge Bowl Oral Practice",
            activityKind: ModuleActivityKind("oral"),
            controls: .voicePractice,
            totalUnits: questions.count
        )
        registeredSession = ModuleCatalog.shared.host.sessionRegistration.begin(
            descriptor,
            onPause: { [weak self] in
                // Pause narration/listening; watch pause maps to skipping the
                // current listen window without ending the session.
                self?.voiceCommandFeedback = "Paused"
            },
            onResume: { [weak self] in
                self?.voiceCommandFeedback = ""
            },
            onMute: nil,
            onStop: { [weak self] in
                guard let self else { return }
                Task { await self.endSession() }
            }
        )
    }

    /// Push current progress to the registered session (and thus the watch).
    private func updateRegisteredProgress() {
        registeredSession?.update(progress: ModuleSessionProgress(
            completedUnits: session.attempts.count
        ))
    }

    func endSession() async {
        if let engine {
            // Engine emits matchEnded, which drives finishSession().
            await engine.stop()
        } else {
            finishSession()
        }
    }

    /// Final teardown, driven by the engine's matchEnded event (or directly
    /// when the session never started the engine).
    private func finishSession() {
        guard !hasFinished else { return }
        hasFinished = true

        stopVoiceCommandMonitoring()
        voiceEventTask?.cancel()
        voiceEventTask = nil
        engineEventTask?.cancel()

        // Hand the exclusive pipeline back.
        let voiceSession = voice
        voice = nil
        Task { await voiceSession?.release() }
        isListening = false
        isSpeaking = false

        session.endTime = Date()
        session.isComplete = true
        state = .completed

        // End the registered session: clears the watch handler, pushes idle,
        // and emits end telemetry (MODULE_SDK_SPEC.md section 5.9).
        registeredSession?.end(summary: ModuleSessionSummary(
            completedUnits: session.attempts.count,
            duration: session.duration
        ))
        registeredSession = nil

        // Announce completion (Hands-Free First)
        let score = session.correctCount
        let total = session.attempts.count
        voiceFeedback.announceActivityCompleted("Session complete. \(score) of \(total) correct.")

        // Save completed session via session manager
        let localAttempts = session.attempts
        let localEndTime = session.endTime
        let sessionId = session.id
        Task {
            do {
                // Sync local session state to manager before completing
                await sessionManager.updateSession { managerSession in
                    managerSession.attempts = localAttempts
                    managerSession.endTime = localEndTime
                    managerSession.isComplete = true
                }
                try await sessionManager.completeSession()
                print("[KB] Oral session saved via manager: \(sessionId)")
            } catch {
                print("[KB] Failed to save oral session: \(error)")
            }
        }
    }

    // MARK: - Question Flow (engine commands)

    func skipConference() async {
        await engine?.skipConference()
    }

    // MARK: - Voice Input

    func toggleListening() async {
        guard let engine else { return }
        if isListening {
            // Stop listening (cancels the in-flight listen; transcript kept)
            await engine.stopListening()
        } else {
            // Start listening for one utterance. Endpointing (silence
            // threshold, max duration) is the acquired pipeline config.
            await engine.startListening()
        }
    }

    func submitAnswer() async {
        await engine?.submitAnswer(transcript)
    }

    // MARK: - Voice Command Handling (Hands-Free First)

    /// Start continuous voice command monitoring for the session
    private func startVoiceCommandMonitoring() {
        voiceCommandTask?.cancel()
        voiceCommandTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Monitor transcript changes for commands
            while !Task.isCancelled && self.state != .completed {
                try? await Task.sleep(nanoseconds: 200_000_000)  // Check every 200ms

                // Skip command detection during answer listening (transcript is answer content)
                guard self.state != .listeningForAnswer else {
                    // During listening, check for explicit submit/done commands
                    await self.checkForSubmitCommand()
                    continue
                }

                // Check transcript for commands in other states
                guard !self.transcript.isEmpty else { continue }

                await self.processVoiceCommand(transcript: self.transcript)
            }
        }
    }

    /// Stop voice command monitoring
    private func stopVoiceCommandMonitoring() {
        voiceCommandTask?.cancel()
        voiceCommandTask = nil
    }

    /// Check for submit/done command during answer listening
    private func checkForSubmitCommand() async {
        guard state == .listeningForAnswer, !transcript.isEmpty else { return }

        // Only check the last few words for submit command
        let words = transcript.lowercased().split(separator: " ")
        let lastWords = words.suffix(3).joined(separator: " ")

        let validCommands: Set<VoiceCommand> = [.submit, .skip]
        if let result = await commandRecognizer.recognize(transcript: lastWords, validCommands: validCommands),
           result.shouldExecute {
            await handleVoiceCommand(result.command)
        }
    }

    /// Process transcript for voice commands based on current state
    private func processVoiceCommand(transcript: String) async {
        let validCommands = validCommandsForState(state)
        guard !validCommands.isEmpty else { return }

        if let result = await commandRecognizer.recognize(transcript: transcript, validCommands: validCommands),
           result.shouldExecute {
            await handleVoiceCommand(result.command)
        }
    }

    /// Get valid commands for current state
    private func validCommandsForState(_ state: KBOralSessionState) -> Set<VoiceCommand> {
        switch state {
        case .notStarted:
            return [.ready, .quit]
        case .readingQuestion:
            return [.skip, .quit]
        case .conferenceTime:
            return [.ready, .quit]
        case .listeningForAnswer:
            return [.submit, .skip]  // Handled separately in checkForSubmitCommand
        case .showingFeedback:
            return [.next, .quit]
        case .completed:
            return [.quit]
        }
    }

    /// Handle a recognized voice command
    private func handleVoiceCommand(_ command: VoiceCommand) async {
        // Provide immediate feedback
        voiceFeedback.announceCommandRecognized(command)
        lastRecognizedCommand = command
        voiceCommandFeedback = "Command: \(command.displayName)"

        // Clear feedback after delay
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.voiceCommandFeedback = ""
            self.lastRecognizedCommand = nil
        }

        // Execute command based on state
        switch (state, command) {
        case (.notStarted, .ready):
            await startSession()

        case (.readingQuestion, .skip):
            // Skip TTS and go to conference time
            await engine?.skipReading()

        case (.conferenceTime, .ready):
            await skipConference()

        case (.listeningForAnswer, .submit):
            await submitAnswer()

        case (.listeningForAnswer, .skip):
            // Mark as skipped and move to feedback (engine emits answerSkipped)
            await engine?.markSkipped()

        case (.showingFeedback, .next):
            await nextQuestion()

        case (_, .quit):
            await endSession()

        default:
            // Invalid command for state
            voiceFeedback.playTone(.commandInvalid)
        }
    }

    func nextQuestion() async {
        transcript = ""
        lastAnswerCorrect = nil
        // The engine advances or, past the last question, ends the match
        // (matchEnded then drives finishSession).
        await engine?.next()
    }
}

// MARK: - Oral Session Errors

/// Module-side errors this session reports into the host error log.
enum KBOralSessionError: LocalizedError {
    case narrationFailed(String)
    case listenFailed(String)

    var errorDescription: String? {
        switch self {
        case .narrationFailed(let message):
            return "Question narration failed: \(message)"
        case .listenFailed(let message):
            return "Answer capture failed: \(message)"
        }
    }
}

// MARK: - Oral Session State

enum KBOralSessionState: Equatable {
    case notStarted
    case readingQuestion
    case conferenceTime
    case listeningForAnswer
    case showingFeedback
    case completed
}

// MARK: - Preview

// MARK: - Haptic Feedback Helper

#if os(iOS)
import UIKit

@MainActor
private enum KBHapticFeedback {
    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }

    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}
#endif

#if DEBUG
struct KBOralSessionView_Previews: PreviewProvider {
    static var previews: some View {
        let engine = KBQuestionEngine.preview()
        let config = KBSessionConfig.quickPractice(
            region: .colorado,
            roundType: .oral,
            questionCount: 5
        )
        let viewModel = KBOralSessionViewModel(
            questions: engine.questions,
            config: config
        )

        NavigationStack {
            KBOralSessionView(viewModel: viewModel)
        }
    }
}
#endif
