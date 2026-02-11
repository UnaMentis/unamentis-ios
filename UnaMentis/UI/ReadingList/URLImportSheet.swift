// UnaMentis - URL Import Sheet
// Sheet view for importing web articles by URL into the reading list.
//
// Part of UI/ReadingList

import SwiftUI

// MARK: - URL Import Sheet

/// Sheet view for entering a URL to import a web article
public struct URLImportSheet: View {
    @ObservedObject var viewModel: ReadingListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlText: String = ""
    @State private var isImporting: Bool = false
    @State private var importError: String?
    @FocusState private var isURLFieldFocused: Bool

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Instructions
                Text("Enter the URL of an article or web page to add to your reading list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // URL input field
                TextField("https://example.com/article", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isURLFieldFocused)
                    .submitLabel(.go)
                    .onSubmit { Task { await importURL() } }
                    .accessibilityLabel("Article URL")

                // Error message
                if let error = importError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Import button
                Button {
                    Task { await importURL() }
                } label: {
                    if isImporting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Importing...")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text("Import Article")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isImporting)
                .accessibilityLabel("Import article from URL")

                Spacer()
            }
            .padding()
            .navigationTitle("Import from URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isImporting)
                }
            }
            .interactiveDismissDisabled(isImporting)
            .onAppear { isURLFieldFocused = true }
        }
    }

    // MARK: - Import Logic

    private func importURL() async {
        // Normalize and validate URL
        var urlString = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "https://" + urlString
        }

        guard let url = URL(string: urlString),
              url.host != nil else {
            importError = "Please enter a valid web address."
            return
        }

        isImporting = true
        importError = nil

        await viewModel.importWebArticle(from: url)

        if let error = viewModel.errorMessage {
            importError = error
            viewModel.errorMessage = nil
            isImporting = false
        } else {
            dismiss()
        }
    }
}

// MARK: - Preview

#Preview {
    URLImportSheet(viewModel: ReadingListViewModel())
}
