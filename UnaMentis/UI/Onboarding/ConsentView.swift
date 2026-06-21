// UnaMentis - Onboarding Consent Page
// Beta age attestation and telemetry consent
//
// Part of UI/UX Help System

import SwiftUI

/// Helper for recording consent metadata in UserDefaults.
///
/// UserDefaults key contract (shared with telemetry consent enforcement):
/// - "ageAttestation13Plus" (Bool, default false)
/// - "ageAttestationDate" (Date, set when the attestation is granted)
/// - "telemetryConsentGranted" (Bool, default false)
enum ConsentRecords {
    /// Records or clears the age attestation timestamp when the attestation changes
    static func recordAgeAttestation(granted: Bool) {
        if granted {
            UserDefaults.standard.set(Date(), forKey: "ageAttestationDate")
        } else {
            UserDefaults.standard.removeObject(forKey: "ageAttestationDate")
        }
    }
}

/// Final onboarding page that collects the required 13+ age attestation and
/// optional telemetry consent before the user can enter the app.
///
/// The age attestation is blocking: OnboardingView disables its final
/// "Get Started" button until the attestation toggle is on. Telemetry
/// consent is optional and defaults to off. Both choices remain revocable
/// in Settings under the Privacy section.
struct OnboardingConsentPageView: View {
    @AppStorage("ageAttestation13Plus") private var ageAttestation13Plus = false
    @AppStorage("telemetryConsentGranted") private var telemetryConsentGranted = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                    .padding(.top, 24)

                // Title and subtitle
                VStack(spacing: 8) {
                    Text("Before You Start")
                        .font(.title.bold())
                        .multilineTextAlignment(.center)

                    Text("Privacy & Eligibility")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }

                // Description
                Text("UnaMentis is for users 13 and older. Please confirm your age and choose whether to share anonymous usage data.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Consent toggles
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: $ageAttestation13Plus) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("I am 13 years of age or older")
                                .font(.subheadline.weight(.medium))
                            Text("Required to use UnaMentis")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHint("Required. Confirms you are at least 13 years old.")

                    Divider()

                    Toggle(isOn: $telemetryConsentGranted) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Share anonymous usage data")
                                .font(.subheadline.weight(.medium))
                            Text("Optional. Latency and reliability metrics only, never conversation content.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityHint("Optional. Shares anonymous performance metrics to help improve the app.")
                }
                .padding(16)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray6))
                }
                .padding(.horizontal, 24)

                // Policy links
                VStack(spacing: 12) {
                    Link("Privacy Policy", destination: URL(string: "https://unamentis.org/privacy.html")!)
                        .font(.footnote)
                    Link("Terms of Use", destination: URL(string: "https://unamentis.org/terms.html")!)
                        .font(.footnote)
                }

                if !ageAttestation13Plus {
                    Text("Confirm the age requirement to continue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 24)
            }
        }
        .onChange(of: ageAttestation13Plus) { _, granted in
            ConsentRecords.recordAgeAttestation(granted: granted)
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingConsentPageView()
}
