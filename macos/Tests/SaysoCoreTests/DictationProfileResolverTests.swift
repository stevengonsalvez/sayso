import Testing
@testable import SaysoCore

@Test func dictationProfileResolverUsesExactBundleOverride() {
    let fallback = DictationProfile(id: "fallback", name: "Everywhere")
    let slack = DictationProfile(id: "slack", name: "Slack")
    let resolver = DictationProfileResolver(
        fallback: fallback,
        overrides: [.init(bundleIdentifier: "com.tinyspeck.slackmacgap", profile: slack)]
    )

    #expect(resolver.resolve(forBundleIdentifier: "com.tinyspeck.slackmacgap") == slack)
    #expect(resolver.resolve(forBundleIdentifier: "com.tinyspeck.slackmacgap.beta") == fallback)
}

@Test func dictationProfileResolverNormalizesBundleIDAndUsesFirstMatch() {
    let fallback = DictationProfile(id: "fallback", name: "Everywhere")
    let first = DictationProfile(id: "first", name: "First")
    let second = DictationProfile(id: "second", name: "Second")
    let resolver = DictationProfileResolver(
        fallback: fallback,
        overrides: [
            .init(bundleIdentifier: "com.apple.mail", profile: first),
            .init(bundleIdentifier: "COM.APPLE.MAIL", profile: second),
        ]
    )

    #expect(resolver.resolve(forBundleIdentifier: "  Com.Apple.Mail  ") == first)
}

@Test func dictationProfileResolverFallsBackWithoutExactApp() {
    let fallback = DictationProfile(id: "fallback", name: "Everywhere")
    let resolver = DictationProfileResolver(
        fallback: fallback,
        overrides: [.init(bundleIdentifier: "com.apple.mail", profile: .init(name: "Mail"))]
    )

    #expect(resolver.resolve(forBundleIdentifier: nil) == fallback)
    #expect(resolver.resolve(forBundleIdentifier: "  ") == fallback)
    #expect(resolver.resolve(forBundleIdentifier: "com.apple.notes") == fallback)
}

@Test func resolvedDictationSettingsAppliesOnlyMatchingAppOverrides() {
    var settings = SaysoSettings()
    settings.language = .english
    settings.route = .local
    settings.translationEnabled = false
    settings.outputLanguage = .english
    settings.cleanupEnabled = false
    settings.dictationProfileOverrides = [
        .init(
            bundleIdentifier: "com.apple.mail",
            profile: .init(
                name: "Mail",
                languageOverride: .hindi,
                routeOverride: .appleSpeech,
                translationEnabledOverride: true,
                outputLanguageOverride: .tamil,
                cleanupEnabledOverride: true
            )
        )
    ]

    let mail = settings.resolvedDictationSettings(forBundleIdentifier: "com.apple.mail")
    let notes = settings.resolvedDictationSettings(forBundleIdentifier: "com.apple.notes")

    #expect(mail.language == .hindi)
    #expect(mail.route == .appleSpeech)
    #expect(mail.translationEnabled)
    #expect(mail.outputLanguage == .tamil)
    #expect(mail.cleanupEnabled)
    #expect(notes.language == .english)
    #expect(notes.route == .local)
    #expect(!notes.translationEnabled)
    #expect(notes.outputLanguage == .english)
    #expect(!notes.cleanupEnabled)
    #expect(settings.language == .english)
    #expect(settings.route == .local)
}
