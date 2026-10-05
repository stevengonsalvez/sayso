import Foundation
import IOKit.pwr_mgt
import Testing
@testable import SaysoCore

/// Names of the power assertions the power manager lists for this test process.
private func assertionNamesHeldByThisProcess() -> [String] {
    var unmanaged: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
          let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
    else { return [] }
    let mine = byProcess.first { $0.key.int32Value == ProcessInfo.processInfo.processIdentifier }?.value ?? []
    return mine.compactMap { $0[kIOPMAssertionNameKey] as? String }
}

/// Runs against the real power manager; each assertion lives for a few milliseconds.
@Suite(.serialized) struct IOPMAssertionPortTests {
    private let name = "Sayso Caffeine test \(UUID().uuidString)"

    @Test func aCreatedAssertionIsListedForThisProcessUntilReleased() throws {
        let assertion = try #require(IOPMAssertionPort().createAssertion(named: name))
        #expect(assertionNamesHeldByThisProcess().contains(name))

        assertion.release()
        #expect(!assertionNamesHeldByThisProcess().contains(name))
        assertion.release()
    }

    @Test func droppingTheHandleReleasesTheAssertion() throws {
        do {
            let assertion = try #require(IOPMAssertionPort().createAssertion(named: name))
            // Without this an optimised build may free the handle before the check.
            withExtendedLifetime(assertion) { #expect(assertionNamesHeldByThisProcess().contains(name)) }
        }
        #expect(!assertionNamesHeldByThisProcess().contains(name))
    }
}
