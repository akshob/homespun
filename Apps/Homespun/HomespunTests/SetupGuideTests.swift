// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import Homespun

@MainActor @Test func everyNASGuideRequiresExistingWritableStorageFolders() {
    for brand in NASBrand.allCases {
        let compose = brand.compose
        #expect(compose.contains("source: ./data\n"))
        #expect(compose.contains("source: \(brand.folder)\n"))
        #expect(compose.components(separatedBy: "create_host_path: false").count == 3)
        #expect(!compose.contains("- ./data:/data"))
        #expect(!compose.contains("- \(brand.folder):/originals"))
    }
}
