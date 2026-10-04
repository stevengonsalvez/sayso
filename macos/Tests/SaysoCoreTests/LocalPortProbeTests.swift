import Foundation
@testable import SaysoCore
import Testing

@Suite("LocalPortProbeTests")
struct LocalPortProbeTests {
    @Test
    func closedPortReturnsFalseInstantly() {
        // Port 59999 should not be listening locally
        let isOpen = LocalPortProbe.isLocalPortOpen(port: 59999, timeoutMs: 50)
        #expect(!isOpen)
    }
}
