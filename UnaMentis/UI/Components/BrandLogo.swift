// UnaMentis - Brand Logo Component
// Reusable logo component for consistent branding across the app

import SwiftUI

/// Reusable brand logo component with configurable size
///
/// Usage:
/// - `.compact` (24pt): For toolbar/navigation bar placement
/// - `.standard` (32pt): For headers and prominent placement
/// - `.large` (48pt): For onboarding and splash screens
struct BrandLogo: View {
    enum Size {
        case compact   // 24pt - toolbar/navigation
        case standard  // 32pt - headers
        case large     // 48pt - onboarding

        var height: CGFloat {
            switch self {
            case .compact: return 24
            case .standard: return 32
            case .large: return 48
            }
        }
    }

    let size: Size

    init(size: Size = .standard) {
        self.size = size
    }

    var body: some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(height: size.height)
            .accessibilityLabel("UnaMentis logo")
            .accessibilityHidden(true)
    }
}

// MARK: - Preview

#Preview("Compact") {
    BrandLogo(size: .compact)
        .padding()
}

#Preview("Standard") {
    BrandLogo(size: .standard)
        .padding()
}

#Preview("Large") {
    BrandLogo(size: .large)
        .padding()
}
