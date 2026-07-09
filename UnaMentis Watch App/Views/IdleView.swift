// UnaMentis Watch App - Idle View
// Shown when no tutoring session is active

import SwiftUI

struct IdleView: View {
    @EnvironmentObject var connectivity: WatchConnectivityService

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text("UnaMentis")
                    .font(.headline)

                Text("No Active Session")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !connectivity.isReachable {
                    Label("iPhone Not Reachable", systemImage: "iphone.slash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                // Module launch links come from WatchModuleCatalog, the single
                // watch-surface registration point (MODULE_SDK_SPEC.md section
                // 8). Nothing hardcodes a KB reference here: adding a
                // watch-capable module is one catalog entry, not an edit here.
                ForEach(WatchModuleCatalog.entries) { entry in
                    NavigationLink {
                        entry.makeRootView()
                    } label: {
                        Label(entry.name, systemImage: entry.iconName)
                    }
                }
            }
            .padding()
        }
    }
}

#Preview {
    IdleView()
        .environmentObject(WatchConnectivityService.shared)
}
