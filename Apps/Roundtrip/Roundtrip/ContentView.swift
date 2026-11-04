// SPDX-License-Identifier: Apache-2.0
import RoundtripCore
import SwiftUI

struct ContentView: View {
    private let profile = CompressionProfile.standard

    var body: some View {
        NavigationStack {
            List {
                Section("Compact copies") {
                    LabeledContent("Photos", value: "up to \(profile.photoMaxEdge) px")
                    LabeledContent("Videos", value: "\(profile.videoShortEdge)p HEVC")
                }
            }
            .navigationTitle("Roundtrip")
        }
    }
}
