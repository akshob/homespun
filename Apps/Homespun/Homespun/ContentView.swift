// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import Photos
import PhotosUI
import SwiftUI

struct ContentView: View {
    @State private var job = CompactJob()
    @State private var selection: [PhotosPickerItem] = []
    @State private var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    private let profile = CompressionProfile.standard

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if access == .authorized {
                        PhotosPicker(selection: $selection, matching: .any(of: [.images, .videos, .livePhotos]),
                                     preferredItemEncoding: .current, photoLibrary: .shared()) {
                            Label("Choose photos and videos", systemImage: "photo.stack")
                        }
                    } else {
                        accessPrompt
                    }
                } header: {
                    Text("On this iPhone")
                } footer: {
                    Text("Compact copies are saved to the \(OnDeviceCompactor.albumTitle) album. "
                         + "Originals are not changed or deleted. Keep Homespun open while it works.")
                }

                if !job.items.isEmpty {
                    Section {
                        ForEach(job.items) { ItemRow(item: $0) }
                    } header: {
                        HStack {
                            Text("Items")
                            Spacer()
                            if !job.isRunning { Button("Clear") { job.clearFinished() }.font(.caption) }
                        }
                    }
                }

                if job.savedOriginalBytes > 0 {
                    Section("Saved this session") {
                        LabeledContent("Originals", value: bytes(job.savedOriginalBytes))
                        LabeledContent("Compact copies", value: bytes(job.savedCompactBytes))
                        LabeledContent("Ratio", value: (Double(job.savedCompactBytes) / Double(job.savedOriginalBytes))
                            .formatted(.percent.precision(.fractionLength(0))))
                    }
                }

                Section("Compact copies") {
                    LabeledContent("Photos", value: "JPEG, up to \(profile.photoMaxEdge) px")
                    LabeledContent("Videos", value: "HEVC, up to \(profile.videoShortEdge)p")
                    LabeledContent("Live Photos", value: "Motion re-encoded, still paired")
                }
            }
            .navigationTitle("Homespun")
            .onChange(of: selection) { _, items in
                let identifiers = items.compactMap(\.itemIdentifier)
                selection = []
                if !identifiers.isEmpty { job.enqueue(identifiers) }
            }
            .onChange(of: scenePhase) { _, phase in
                // Access may have changed in Settings.
                if phase == .active { access = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
            }
            .task {
                if access == .notDetermined {
                    access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                }
            }
        }
    }

    @ViewBuilder private var accessPrompt: some View {
        switch access {
        case .notDetermined:
            Button("Allow access to Photos") {
                Task { access = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text("Homespun needs access to all photos to read originals and save compact copies.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        }
    }
}

private struct ItemRow: View {
    let item: CompactJob.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                status.font(.caption)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .waiting:
            Text("Waiting").foregroundStyle(.secondary)
        case .working(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(message)
            }.foregroundStyle(.secondary)
        case .saved(let original, let compact):
            Text("\(bytes(original)) → \(bytes(compact))").foregroundStyle(.green)
        case .unchanged(let reason):
            Text(reason).foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason).foregroundStyle(.red)
        }
    }
}

private func bytes(_ count: Int) -> String {
    Int64(count).formatted(.byteCount(style: .file))
}
