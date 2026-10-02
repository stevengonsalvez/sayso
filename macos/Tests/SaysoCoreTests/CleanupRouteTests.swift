import Testing
@testable import SaysoCore

private func route(
    mode: CleanupMode = .rules, cloudEnabled: Bool = false, consent: Bool = true,
    hasKey: Bool = true, hasBaseURL: Bool = true, hasModel: Bool = true
) -> CleanupRoute {
    CleanupRoute.resolve(
        mode: mode, cloudCleanupEnabled: cloudEnabled, byokConsentGranted: consent,
        hasCloudKey: hasKey, hasCloudBaseURL: hasBaseURL, hasCloudModel: hasModel
    )
}

@Test func rulesModeStaysLocalEvenIfCloudFlagIsOff() {
    #expect(route(mode: .rules) == .rules)
}

@Test func localSLMModeAlwaysRoutesToTheLocalModel() {
    #expect(route(mode: .localSLM, cloudEnabled: true) == .localSLM)
}

@Test func cloudNeedsConsentKeyBaseURLAndModelOtherwiseFallsBackToRules() {
    #expect(route(mode: .cloudLLM) == .cloud)
    #expect(route(cloudEnabled: true) == .cloud)
    #expect(route(mode: .cloudLLM, consent: false) == .rules)
    #expect(route(mode: .cloudLLM, hasKey: false) == .rules)
    #expect(route(mode: .cloudLLM, hasBaseURL: false) == .rules)
    #expect(route(mode: .cloudLLM, hasModel: false) == .rules)
}
