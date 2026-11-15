// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation
import StoreKit

/// Homespun Premium: a one-time purchase that unlocks automatic mode and cloud copies.
/// Everything else, including freeing up space, stays free. Builds made in Xcode (Debug)
/// are unlocked, so the owner's own builds never need a purchase, and so are TestFlight builds
/// while the App Store has no Premium product yet.
@MainActor @Observable
final class Premium {
    nonisolated static let productID = "photos.homespun.app.premium"

    /// Bought (or restored) through the App Store.
    private(set) var purchased = false
    private(set) var product: Product?
    private(set) var loading = false
    /// A Debug build: unlocked without a purchase (`-premiumLocked YES` locks it for testing).
    let ownBuild: Bool
    /// A TestFlight build while the App Store has no Premium product: unlocked so testers can try
    /// everything. Once the product exists, TestFlight shows the real (free, sandbox) purchase.
    private(set) var beta = false
    private var betaChecked = false
    private let testFlightWithoutProduct: @Sendable () async -> Bool
    private var updates: Task<Void, Never>?
    /// Whether this Apple Account owns Premium (the App Store, or a stand-in in tests).
    private let owned: @Sendable () async -> Bool

    var isUnlocked: Bool { purchased || ownBuild || beta }

    static var isOwnBuild: Bool {
        #if DEBUG
        !UserDefaults.standard.bool(forKey: "premiumLocked")
        #else
        false
        #endif
    }

    init(ownBuild: Bool = Premium.isOwnBuild, owned: @escaping @Sendable () async -> Bool = Premium.ownedOnAppStore,
         testFlightWithoutProduct: @escaping @Sendable () async -> Bool = Premium.isTestFlightWithoutProduct,
         listens: Bool = true) {
        self.ownBuild = ownBuild
        self.owned = owned
        self.testFlightWithoutProduct = testFlightWithoutProduct
        guard listens else { return }
        // Purchases made elsewhere (another device, Family Sharing, Ask to Buy) and refunds.
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
    }

    /// Loads the product and checks what this Apple Account owns.
    func load() async {
        loading = true
        defer { loading = false }
        if product == nil { product = try? await Product.products(for: [Self.productID]).first }
        await refresh()
    }

    func refresh() async {
        purchased = await owned()
        // Once per launch: a product added meanwhile shows up the next time the app starts.
        if !ownBuild, !betaChecked {
            betaChecked = true
            beta = await testFlightWithoutProduct()
        }
    }

    /// TestFlight (StoreKit's sandbox) and the App Store doesn't know the Premium product. A failed
    /// request counts as "has a product", so a network problem never unlocks anything.
    nonisolated static func isTestFlightWithoutProduct() async -> Bool {
        guard case .verified(let app)? = try? await AppTransaction.shared, app.environment == .sandbox else { return false }
        return (try? await Product.products(for: [productID]))?.isEmpty ?? false
    }

    /// A verified, unrevoked Premium transaction (bought, restored, or shared with the family).
    nonisolated static func ownedOnAppStore() async -> Bool {
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement, transaction.productID == productID,
               transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    enum Outcome: Equatable { case purchased, cancelled, pending }

    func purchase() async throws -> Outcome {
        if product == nil { await load() }
        guard let product else { throw PurchaseError.unavailable }
        switch try await product.purchase() {
        case .success(let result):
            guard case .verified(let transaction) = result else { throw PurchaseError.unverified }
            await transaction.finish()
            await refresh()
            return .purchased
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: return .cancelled
        }
    }

    /// Asks the App Store again for this Apple Account's purchases.
    func restore() async throws {
        try await AppStore.sync()
        await refresh()
    }

    enum PurchaseError: LocalizedError {
        case unavailable, unverified
        var errorDescription: String? {
            switch self {
            case .unavailable: "The App Store isn't available right now. Try again later."
            case .unverified: "The App Store couldn't confirm the purchase."
            }
        }
    }
}
