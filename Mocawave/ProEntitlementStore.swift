import Combine
import Foundation
import StoreKit

private let defaultProProductID = "mocawave.pro.lifetime"

struct ProStoreProduct: Equatable {
    let id: String
    let displayName: String
    let description: String
    let displayPrice: String
}

enum ProPurchaseOutcome: Equatable {
    case purchased
    case pending
    case userCancelled
}

enum ProPurchaseState: Equatable {
    case idle
    case purchasing
    case restoring
    case pending
    case purchased
    case restored
    case cancelled
    case failed(String)
}

protocol ProStoreBackend {
    var updates: AsyncStream<Void> { get }
    func fetchProducts(identifiers: Set<String>) async throws -> [ProStoreProduct]
    func currentEntitlements(for identifiers: Set<String>) async -> Set<String>
    func purchase(productID: String) async throws -> ProPurchaseOutcome
    func restorePurchases() async throws
}

enum ProStoreRuntime {
    static func defaultBackend(bundle: Bundle = .main) -> ProStoreBackend {
        if let reason = unavailableReason(bundle: bundle) {
            return UnavailableProStoreBackend(reason: reason)
        }
        return StoreKitProStoreBackend()
    }

    static func unavailableReason(bundle: Bundle = .main) -> String? {
        let bundleIdentifier = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let packageType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String

        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return "App Store purchases require launching Mocawave from Mocawave.app. The current process has no bundle identifier, so StoreKit is unavailable."
        }

        guard packageType == "APPL" else {
            return "App Store purchases require launching Mocawave from Mocawave.app. The current process is not running as an app bundle (\(bundleIdentifier))."
        }

        return nil
    }
}

struct UnavailableProStoreBackend: ProStoreBackend, Sendable {
    let reason: String

    var updates: AsyncStream<Void> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func fetchProducts(identifiers: Set<String>) async throws -> [ProStoreProduct] {
        throw ProStoreError.storeUnavailable(reason)
    }

    func currentEntitlements(for identifiers: Set<String>) async -> Set<String> {
        []
    }

    func purchase(productID: String) async throws -> ProPurchaseOutcome {
        throw ProStoreError.storeUnavailable(reason)
    }

    func restorePurchases() async throws {
        throw ProStoreError.storeUnavailable(reason)
    }
}

struct StoreKitProStoreBackend: ProStoreBackend, Sendable {
    var updates: AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard case .verified(let transaction) = result else { continue }
                    await transaction.finish()
                    continuation.yield()
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func fetchProducts(identifiers: Set<String>) async throws -> [ProStoreProduct] {
        let products = try await Product.products(for: Array(identifiers))
        return products
            .sorted { $0.id < $1.id }
            .map {
                ProStoreProduct(
                    id: $0.id,
                    displayName: $0.displayName,
                    description: $0.description,
                    displayPrice: $0.displayPrice
                )
            }
    }

    func currentEntitlements(for identifiers: Set<String>) async -> Set<String> {
        var activeProductIDs: Set<String> = []

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard identifiers.contains(transaction.productID) else { continue }
            guard transaction.revocationDate == nil else { continue }
            activeProductIDs.insert(transaction.productID)
        }

        return activeProductIDs
    }

    func purchase(productID: String) async throws -> ProPurchaseOutcome {
        let products = try await Product.products(for: [productID])
        guard let product = products.first else {
            throw ProStoreError.productNotFound(productID)
        }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try Self.checkVerified(verification)
            await transaction.finish()
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            return .pending
        }
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
    }

    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified(_, let error):
            throw error
        }
    }
}

enum ProStoreError: LocalizedError, Equatable {
    case productNotFound(String)
    case storeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .productNotFound(let productID):
            return "The App Store product \(productID) is unavailable."
        case .storeUnavailable(let reason):
            return reason
        }
    }
}

@MainActor
final class ProEntitlementStore: ObservableObject {
    static let shared = ProEntitlementStore(developmentOverrideEnabled: ProFeatures.developerOverrideEnabled)
    nonisolated static let proProductID = defaultProProductID

    @Published private(set) var hasPurchasedPro = false
    @Published private(set) var products: [ProStoreProduct] = []
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var purchaseState: ProPurchaseState = .idle
    @Published private(set) var productLoadError: String?

    private let backend: ProStoreBackend
    private let productIDs: Set<String>
    private let developmentOverrideEnabled: Bool
    private var updatesTask: Task<Void, Never>?
    private var hasPreparedStore = false

    init(
        backend: ProStoreBackend = ProStoreRuntime.defaultBackend(),
        productIDs: Set<String> = [defaultProProductID],
        developmentOverrideEnabled: Bool = false
    ) {
        self.backend = backend
        self.productIDs = productIDs
        self.developmentOverrideEnabled = developmentOverrideEnabled
        self.updatesTask = observeTransactionUpdates()
    }

    deinit {
        updatesTask?.cancel()
    }

    var effectiveProAccess: Bool {
        developmentOverrideEnabled || hasPurchasedPro
    }

    var proProduct: ProStoreProduct? {
        products.first { $0.id == Self.proProductID }
    }

    func prepareIfNeeded() async {
        guard !hasPreparedStore else {
            if products.isEmpty {
                await loadProducts()
            }
            await refreshEntitlements()
            return
        }

        hasPreparedStore = true
        await loadProducts()
        await refreshEntitlements()
    }

    func clearPurchaseStateIfNeeded() {
        switch purchaseState {
        case .purchased, .restored, .cancelled, .failed:
            purchaseState = .idle
        case .idle, .purchasing, .restoring, .pending:
            break
        }
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }

        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let fetchedProducts = try await backend.fetchProducts(identifiers: productIDs)
            products = fetchedProducts
            productLoadError = fetchedProducts.isEmpty ? "The Pro product is not available in App Store Connect yet." : nil
        } catch {
            products = []
            productLoadError = Self.userFacingMessage(for: error)
        }
    }

    func refreshEntitlements() async {
        let activeProductIDs = await backend.currentEntitlements(for: productIDs)
        hasPurchasedPro = activeProductIDs.contains(Self.proProductID)
    }

    func purchasePro() async {
        clearPurchaseStateIfNeeded()

        if products.isEmpty {
            await loadProducts()
        }

        guard let product = proProduct else {
            purchaseState = .failed(productLoadError ?? "The Pro purchase is unavailable right now.")
            return
        }

        purchaseState = .purchasing
        do {
            let outcome = try await backend.purchase(productID: product.id)
            switch outcome {
            case .purchased:
                await refreshEntitlements()
                purchaseState = effectiveProAccess
                    ? .purchased
                    : .failed("The purchase finished, but Pro access could not be confirmed yet.")
            case .pending:
                purchaseState = .pending
            case .userCancelled:
                purchaseState = .cancelled
            }
        } catch {
            purchaseState = .failed(Self.userFacingMessage(for: error))
        }
    }

    func restorePurchases() async {
        clearPurchaseStateIfNeeded()
        purchaseState = .restoring

        do {
            try await backend.restorePurchases()
            await refreshEntitlements()
            purchaseState = effectiveProAccess
                ? .restored
                : .failed("No previous Pro purchase was found for this Apple Account.")
        } catch {
            purchaseState = .failed(Self.userFacingMessage(for: error))
        }
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            for await _ in backend.updates {
                await self.refreshEntitlements()
            }
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}
