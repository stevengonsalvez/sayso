import Foundation

public struct HandsFreeCycle: Equatable, Sendable {
    public static let deliveryLimit = 50

    public private(set) var isArmed = false
    private var startedAt: Date?
    private var deliveredPhraseCount = 0

    public init() {}

    public mutating func start(
        rearmRequested: Bool,
        handsFreeEnabled: Bool,
        isDictationMode: Bool,
        now: Date = .now
    ) {
        guard rearmRequested && handsFreeEnabled && isDictationMode else {
            disarm()
            return
        }
        if !isArmed {
            startedAt = now
            deliveredPhraseCount = 0
        }
        isArmed = true
    }

    public mutating func disarm() {
        isArmed = false
        startedAt = nil
        deliveredPhraseCount = 0
    }

    public func shouldRearm(
        handsFreeEnabled: Bool,
        isDictationMode: Bool,
        continuousEnabled: Bool = true
    ) -> Bool {
        isArmed && handsFreeEnabled && isDictationMode && continuousEnabled
    }

    public mutating func consumeDelivery(
        wasDelivered: Bool,
        handsFreeEnabled: Bool,
        isDictationMode: Bool,
        continuousEnabled: Bool = true,
        maximumSessionDuration: TimeInterval = 900,
        now: Date = .now
    ) -> Bool {
        deliveredPhraseCount += 1
        let elapsed = now.timeIntervalSince(startedAt ?? now)
        let shouldRearm = wasDelivered
            && shouldRearm(
                handsFreeEnabled: handsFreeEnabled,
                isDictationMode: isDictationMode,
                continuousEnabled: continuousEnabled
            )
            && elapsed < maximumSessionDuration
            && deliveredPhraseCount < Self.deliveryLimit
        if !shouldRearm { disarm() }
        return shouldRearm
    }
}
