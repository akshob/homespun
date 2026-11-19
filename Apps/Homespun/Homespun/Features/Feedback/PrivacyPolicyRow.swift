// SPDX-License-Identifier: Apache-2.0
import SwiftUI

struct PrivacyPolicyRow: View {
    var body: some View {
        Link(destination: URL(string: "https://homespun.photos/privacy")!) {
            ServerRow(title: "Privacy Policy", symbol: "hand.raised", value: nil)
        }
        .accessibilityIdentifier("privacy.policy")
    }
}
