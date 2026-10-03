import Testing
@testable import SaysoCore

private let tabs = ["history": 2, "models": 4, "tts": 9]

@Test func routesResolveToStudioTabsWithSensibleFallbacks() {
    func tab(_ route: SaysoStudioRoute) -> Int {
        SaysoStudioNavigation.tab(for: route, moduleTabs: tabs, settingsTab: 10, defaultTab: 0)
    }
    #expect(tab(.module(id: "history", surface: .detail)) == 2)
    #expect(tab(.module(id: "external", surface: .settings)) == 0)
    #expect(tab(.permissionPrompt(id: "history", capabilities: [.microphone])) == 10)
    #expect(tab(.moduleList) == 0)
}

@Test func capabilitiesMapToTheSystemPermissionsThatGrantThem() {
    #expect(SaysoStudioNavigation.permissions(for: .microphone) == [.microphone])
    #expect(SaysoStudioNavigation.permissions(for: .accessibility) == [.accessibility])
    #expect(SaysoStudioNavigation.permissions(for: .clipboard) == [])
    #expect(SaysoStudioNavigation.permissions(for: .network) == [])
}

@Test func aCapabilityIsGrantedOnlyWhenEveryBackingPermissionIs() {
    let granted: Set<PermissionKind> = [.microphone]
    #expect(SaysoStudioNavigation.isGranted(.microphone, grantedPermissions: granted))
    #expect(!SaysoStudioNavigation.isGranted(.accessibility, grantedPermissions: granted))
    #expect(SaysoStudioNavigation.isGranted(.clipboard, grantedPermissions: []))
}
