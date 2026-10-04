import Testing
@testable import SaysoNotch
import SaysoCore

/// Proves the app target is importable from tests. Constructing `SaysoAppModel` registers global hotkeys,
/// reads the Keychain and opens sockets, so app-model tests need an injectable, side-effect-free
/// construction path first; until then only side-effect-free app types are reachable here.
@Test func theAppModuleIsImportableFromTests() {
    #expect(SaysoShortcutManager.self == SaysoShortcutManager.self)
}
