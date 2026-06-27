// UnaMentis - On-Device LLM Settings View
// Settings UI for managing the on-device LLM model
//
// Part of UI/Settings

import SwiftUI

/// Settings view for on-device LLM model management
///
/// Features:
/// - Download model from Hugging Face
/// - View download progress
/// - Delete model with clear warnings
/// - Show model information and benefits
struct OnDeviceLLMSettingsView: View {

    @StateObject private var viewModel = OnDeviceLLMSettingsViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false

    var body: some View {
        List {
            // Model Status
            modelStatusSection

            // What This Model Does
            if !viewModel.isDownloaded {
                benefitsSection
            }

            // Model Information
            modelInfoSection

            // Storage Management
            if viewModel.isDownloaded {
                storageSection
            }
        }
        .navigationTitle("On-Device LLM")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            Task {
                await viewModel.refreshState()
            }
        }
        .alert("Delete On-Device LLM?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteModel()
                }
            }
        } message: {
            Text("This will remove the on-device model (\(OnDeviceLLMModelInfo.downloadSizeText)) from your device. You can re-download it anytime.\n\nWithout this model, some learning modules may have reduced functionality when offline.")
        }
    }

    // MARK: - Model Status Section

    private var modelStatusSection: some View {
        Section {
            HStack {
                modelStatusIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.modelStateDescription)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(modelStatusSubtext)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Download/Loading progress
            if viewModel.isDownloading || viewModel.isLoading {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: viewModel.progress)
                        .progressViewStyle(.linear)

                    if viewModel.isDownloading {
                        HStack {
                            Text("Downloading from Hugging Face...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(viewModel.progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Action buttons based on state
            actionButtons

        } header: {
            Text("Model Status")
        } footer: {
            #if LLAMA_AVAILABLE
            if viewModel.isDownloaded {
                Text("Model is stored locally and works offline. No internet required for inference.")
            } else {
                Text("Download requires \(OnDeviceLLMModelInfo.downloadSizeText). The model will be stored on your device for offline use.")
            }
            #else
            Text("This build does not include the on-device LLM runtime, so the \(OnDeviceLLMModelInfo.downloadSizeText) download is disabled. Self-hosted and cloud AI are unaffected.")
            #endif
        }
    }

    /// Shown in place of download/load actions when the build lacks the LLM runtime
    private var runtimeUnavailableNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("Requires an on-device build")
                    .font(.subheadline.weight(.medium))
                Text("The on-device LLM runtime is not included in this build. The model cannot be downloaded or loaded here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch viewModel.modelState {
        case .notDownloaded:
            // Only offer the download when the build includes the LLM runtime.
            // Without LLAMA_AVAILABLE no code path can load the model, so the
            // 2.2 GB download would waste storage and bandwidth.
            #if LLAMA_AVAILABLE
            Button {
                Task {
                    await viewModel.downloadModel()
                }
            } label: {
                HStack {
                    Label("Download Model", systemImage: "arrow.down.circle")
                    Spacer()
                    Text(OnDeviceLLMModelInfo.downloadSizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!viewModel.hasEnoughStorage)

            if !viewModel.hasEnoughStorage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Not enough storage space")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            #else
            runtimeUnavailableNote
            #endif

        case .downloading:
            Button(role: .destructive) {
                Task {
                    await viewModel.cancelDownload()
                }
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }

        case .available:
            // A model downloaded by an earlier build may exist on disk.
            // Loading still requires the runtime; deletion stays available
            // through the storage section so testers can reclaim space.
            #if LLAMA_AVAILABLE
            Button {
                Task {
                    await viewModel.loadModel()
                }
            } label: {
                Label("Load Model", systemImage: "cpu")
            }
            .disabled(viewModel.isLoading)
            #else
            runtimeUnavailableNote
            #endif

        case .loaded:
            Button {
                Task {
                    await viewModel.unloadModel()
                }
            } label: {
                Label("Unload Model", systemImage: "cpu.fill")
            }

        case .verifying, .loading:
            EmptyView()

        case .error:
            Button {
                Task {
                    await viewModel.refreshState()
                }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }
    }

    private var modelStatusIcon: some View {
        Group {
            switch viewModel.modelState {
            case .notDownloaded:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.blue)
            case .downloading:
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
            case .verifying:
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.orange)
            case .available:
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
            case .loading:
                Image(systemName: "cpu")
                    .foregroundStyle(.blue)
            case .loaded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.title2)
    }

    private var modelStatusSubtext: String {
        switch viewModel.modelState {
        case .notDownloaded:
            return "Download to enable on-device AI"
        case .downloading:
            return "Downloading from Hugging Face..."
        case .verifying:
            return "Verifying download..."
        case .available:
            return "Ready to load (\(viewModel.modelSizeMB) MB)"
        case .loading:
            return "Loading into memory..."
        case .loaded:
            return "Ready for inference"
        case .error(let message):
            return message
        }
    }

    // MARK: - Benefits Section

    private var benefitsSection: some View {
        Section {
            ForEach(OnDeviceLLMModelInfo.keepModelReasons, id: \.self) { reason in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                    Text(reason)
                        .font(.subheadline)
                }
            }
        } header: {
            Text("Why Download?")
        } footer: {
            Text("The on-device LLM enables advanced features that work without an internet connection.")
        }
    }

    // MARK: - Model Info Section

    private var modelInfoSection: some View {
        Section {
            InfoRow(label: "Model", value: OnDeviceLLMModelInfo.displayName)
            InfoRow(label: "Version", value: OnDeviceLLMModelInfo.version)
            InfoRow(label: "Publisher", value: OnDeviceLLMModelInfo.publisher)
            InfoRow(label: "Size", value: "\(Int(OnDeviceLLMModelInfo.totalSizeMB)) MB")
            InfoRow(label: "Quantization", value: OnDeviceLLMModelInfo.quantization)
            InfoRow(label: "Context Window", value: "\(OnDeviceLLMModelInfo.contextSize) tokens")
            InfoRow(label: "Min RAM", value: "\(OnDeviceLLMModelInfo.minimumRAMGB) GB")
            InfoRow(label: "License", value: OnDeviceLLMModelInfo.license)
        } header: {
            Text("Model Information")
        } footer: {
            Text("\(OnDeviceLLMModelInfo.displayName) is a compact, efficient language model optimized for on-device inference on Apple Silicon.")
        }
    }

    // MARK: - Storage Section

    private var storageSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage Used")
                        .font(.subheadline)
                    Text("\(viewModel.modelSizeMB) MB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            // Warning about deletion
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Before You Delete")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                ForEach(OnDeviceLLMModelInfo.deletionConsequences, id: \.self) { consequence in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\u{2022}")
                            .foregroundStyle(.secondary)
                        Text(consequence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

        } header: {
            Text("Storage Management")
        } footer: {
            Text("You can re-download the model anytime from Settings.")
        }
    }
}

// MARK: - View Model

@MainActor
final class OnDeviceLLMSettingsViewModel: ObservableObject {
    @Published var modelState: OnDeviceLLMModelManager.ModelState = .notDownloaded
    @Published var progress: Float = 0.0
    @Published var modelSizeMB: Int = 0
    @Published var errorMessage: String?

    private var modelManager: OnDeviceLLMModelManager?
    private var refreshTask: Task<Void, Never>?

    init() {
        Task {
            await setupModelManager()
        }
    }

    private func setupModelManager() async {
        modelManager = OnDeviceLLMModelManager.shared
        await refreshState()
    }

    func refreshState() async {
        guard let manager = modelManager else { return }

        modelState = await manager.currentState()
        modelSizeMB = await manager.modelSizeMB()

        if case .downloading(let p) = modelState {
            progress = p
        }
    }

    var modelStateDescription: String {
        modelState.displayText
    }

    var isDownloaded: Bool {
        switch modelState {
        case .available, .loading, .loaded:
            return true
        default:
            return false
        }
    }

    var isDownloading: Bool {
        if case .downloading = modelState { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = modelState { return true }
        return false
    }

    var hasEnoughStorage: Bool {
        // Check for ~3 GB free (model + temp file during download)
        let requiredBytes: Int64 = 3_000_000_000
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let freeSpace = attrs[.systemFreeSize] as? Int64 ?? 0
            return freeSpace >= requiredBytes
        } catch {
            return true // Assume we have space if we can't check
        }
    }

    func downloadModel() async {
        guard let manager = modelManager else { return }

        // Start progress monitoring
        refreshTask = Task {
            while !Task.isCancelled {
                await refreshState()
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }

        do {
            try await manager.downloadModel()
            await refreshState()
        } catch {
            errorMessage = error.localizedDescription
            await refreshState()
        }

        refreshTask?.cancel()
    }

    func cancelDownload() async {
        guard let manager = modelManager else { return }
        await manager.cancelDownload()
        refreshTask?.cancel()
        await refreshState()
    }

    func deleteModel() async {
        guard let manager = modelManager else { return }

        do {
            try await manager.deleteModel()
            await refreshState()
        } catch {
            errorMessage = error.localizedDescription
            await refreshState()
        }
    }

    func loadModel() async {
        // TODO: Integrate with OnDeviceLLMService
        // For now, just mark as loaded
        guard let manager = modelManager else { return }
        await manager.markLoaded()
        await refreshState()
    }

    func unloadModel() async {
        guard let manager = modelManager else { return }
        await manager.markUnloaded()
        await refreshState()
    }
}

// MARK: - Helper Views

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        OnDeviceLLMSettingsView()
    }
}
