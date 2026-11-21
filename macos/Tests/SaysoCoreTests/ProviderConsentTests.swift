import Testing
@testable import SaysoCore

@Test func switchingCloudProviderClearsConsent() {
    var settings = SaysoSettings()
    settings.selectCloudProvider("deepgram")
    settings.byokConsentGranted = true
    #expect(settings.hasConsent(for: .byok))

    settings.selectCloudProvider("custom")
    #expect(settings.selectedCloudProviderId == "custom")
    #expect(!settings.hasConsent(for: .byok))
}

@Test func pickingTheSameCloudProviderKeepsConsent() {
    var settings = SaysoSettings()
    settings.selectCloudProvider("deepgram")
    settings.byokConsentGranted = true
    settings.selectCloudProvider("deepgram")
    #expect(settings.hasConsent(for: .byok))
}
