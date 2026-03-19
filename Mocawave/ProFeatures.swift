import Foundation

@MainActor
enum ProFeatures {
    private static let developmentOverrideFlag: Bool = false

    static var isEnabled: Bool {
        ProEntitlementStore.shared.effectiveProAccess
    }

    static var developerOverrideEnabled: Bool {
        developmentOverrideFlag && isLocalDevelopmentBuild
    }

    private static var isLocalDevelopmentBuild: Bool {
        #if LOCAL_DEV
        true
        #else
        false
        #endif
    }
}
