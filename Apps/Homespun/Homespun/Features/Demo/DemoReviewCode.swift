// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security
import SwiftUI

struct DemoReviewCodeStore: Sendable {
    var service = "photos.homespun.demo-review-code"

    func read() -> String? {
        var result: AnyObject?
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ code: String) throws {
        let code = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        if code.isEmpty { try remove(); return }
        guard code.utf8.count <= 64, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let attributes: [CFString: Any] = [
            kSecValueData: Data(code.utf8), kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: "review", kSecAttrSynchronizable: false]
    }
}

struct DemoReviewCodeButton: View {
    @State private var editing = false
    @State private var code = ""
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        Button("Have a review code?") {
            code = DemoReviewCodeStore().read() ?? ""
            problem = nil
            editing = true
        }
        .font(.footnote)
        .accessibilityIdentifier("demo.review")
        .disabled(DemoMode.shared.isPreparing || DemoMode.shared.isOn || DemoMode.shared.settling)
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form {
                    Section {
                        SecureField("Review code", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .accessibilityIdentifier("demo.review.code")
                    } footer: {
                        Text("For App Review only. With a code, Homespun downloads sample photos from its own server. "
                             + "Your code stays in this iPhone's Keychain. Clear it to return to drawn photos.")
                    }
                    if let problem { Text(problem).foregroundStyle(Theme.secondaryLabel) }
                    Button("Clear Code") { code = ""; save() }
                        .accessibilityIdentifier("demo.review.clear")
                }
                .navigationTitle("Review Code")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }.disabled(saving).accessibilityIdentifier("demo.review.save")
                    }
                }
                .interactiveDismissDisabled(saving)
            }
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                try DemoReviewCodeStore().save(code)
                try await DemoMediaStore.shared.reset()
                editing = false
            } catch {
                problem = "The code couldn't be saved. Try again."
            }
            saving = false
        }
    }
}
