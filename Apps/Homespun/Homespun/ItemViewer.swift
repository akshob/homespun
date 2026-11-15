// SPDX-License-Identifier: Apache-2.0
import Photos
import SwiftUI

/// One item, full screen, with its state and the one action that fits it (DESIGN 03·1.1).
struct ItemViewer: View {
    let model: AppModel
    let ids: [String]
    let start: String
    var freeUp: (Set<String>?) -> Void
    @State private var current: String?
    @State private var image: UIImage?

    private var cell: LibraryState.Cell? {
        model.library.library.state.cells.first { $0.id == (current ?? start) }
    }

    var body: some View {
        Color.black.ignoresSafeArea()
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
            }
            .overlay(alignment: .bottom) {
                if let cell {
                    Label(cell.badge.spoken(server: model.library.serverName), systemImage: cell.badge.symbol ?? "circle.dashed")
                        .font(.subheadline).foregroundStyle(.white).padding().glassEffect()
                        .accessibilityIdentifier("item.state")
                        .padding(.bottom, 24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .task(id: current ?? start) { await load(current ?? start) }
    }

    private func load(_ id: String) async {
        guard let asset = PhotoLibrary.asset(id) else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 2048, height: 2048),
                                              contentMode: .aspectFit, options: options) { result, _ in
            MainActor.assumeIsolated { if let result { image = result } }
        }
    }
}
