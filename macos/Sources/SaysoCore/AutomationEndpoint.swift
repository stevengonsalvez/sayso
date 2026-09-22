import Foundation

public enum SaysoAutomationEndpoint {
    public static let socketPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SaysoNotch/Automation/automation.sock").path
}
