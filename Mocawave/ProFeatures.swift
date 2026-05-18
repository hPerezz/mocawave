import Foundation

@MainActor
enum ProFeatures {
    private static let developmentOverrideFlag: Bool = true

    static var isEnabled: Bool {
        ProEntitlementStore.shared.effectiveProAccess
    }

    static var developerOverrideEnabled: Bool {
        developmentOverrideFlag
    }

    private static var isLocalDevelopmentBuild: Bool {
        #if LOCAL_DEV
        true
        #else
        false
        #endif
    }
}
