import RevenueCat
import SwiftUI

/// Manages tip jar IAP via RevenueCat.
/// Any tip tier unlocks unlimited rips + premium features.
@MainActor @Observable
final class StoreKitService {
    private(set) var isUnlimitedRips = false
    private(set) var offerings: [Package] = []
    private(set) var purchasedTier: String?
    private(set) var purchaseError: String?

    static let apiKey = "appl_ArfKCXEJoNiSlDFHqJwMCLYImFq"

    static let tipProductIDs: Set<String> = [
        "com.lavailabs.ygorip.tip.support",
        "com.lavailabs.ygorip.tip.super",
        "com.lavailabs.ygorip.tip.legendary"
    ]

    weak var appState: AppState?

    nonisolated init() {}

    // MARK: - Configure (call once at app launch)

    func configure() {
        Purchases.logLevel = .error
        Purchases.configure(withAPIKey: Self.apiKey)

        Task {
            await checkEntitlement()
            await loadOfferings()
        }
    }

    // MARK: - Load Offerings

    func loadOfferings() async {
        do {
            let offerings = try await Purchases.shared.offerings()
            if let current = offerings.current {
                self.offerings = current.availablePackages.sorted {
                    $0.storeProduct.price < $1.storeProduct.price
                }
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Purchase

    func purchase(_ package: Package) async {
        purchaseError = nil
        print("[StoreKit] Attempting purchase: \(package.storeProduct.productIdentifier)")

        do {
            let result = try await Purchases.shared.purchase(package: package)
            print("[StoreKit] Purchase result — cancelled: \(result.userCancelled)")
            if !result.userCancelled {
                isUnlimitedRips = true
                purchasedTier = package.storeProduct.productIdentifier
                // Sync to AppState so the rest of the app knows
                syncToAppState()
            }
        } catch {
            print("[StoreKit] Purchase error: \(error)")
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Restore

    private(set) var isRestoring = false
    private(set) var restoreMessage: String?

    func restore() async {
        purchaseError = nil
        restoreMessage = nil
        isRestoring = true

        do {
            let info = try await Purchases.shared.restorePurchases()
            checkCustomerInfo(info)
            restoreMessage = isUnlimitedRips
                ? "Purchases restored!"
                : "No previous purchases found."
        } catch {
            purchaseError = error.localizedDescription
        }

        isRestoring = false
    }

    // MARK: - Entitlement Check

    func checkEntitlement() async {
        do {
            let info = try await Purchases.shared.customerInfo()
            checkCustomerInfo(info)
        } catch {
            // Silently fail — offline users keep their cached state
        }
    }

    private func checkCustomerInfo(_ info: CustomerInfo) {
        // Check entitlement (RevenueCat best practice) — falls back to product ID check
        if info.entitlements["Unlimited Rips"]?.isActive == true {
            isUnlimitedRips = true
        } else {
            // Fallback: check non-subscription purchases directly
            let hasAnyTip = info.nonSubscriptions.contains { purchase in
                Self.tipProductIDs.contains(purchase.productIdentifier)
            }
            isUnlimitedRips = hasAnyTip
        }
        syncToAppState()
    }

    private func syncToAppState() {
        appState?.isUnlimitedRips = isUnlimitedRips
    }
}
