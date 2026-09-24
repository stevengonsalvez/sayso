public struct HandsFreeCycle: Equatable, Sendable {
    public private(set) var isArmed = false

    public init() {}

    public mutating func start(
        rearmRequested: Bool,
        handsFreeEnabled: Bool,
        isDictationMode: Bool
    ) {
        isArmed = rearmRequested && handsFreeEnabled && isDictationMode
    }

    public mutating func disarm() {
        isArmed = false
    }

    public func shouldRearm(handsFreeEnabled: Bool, isDictationMode: Bool) -> Bool {
        isArmed && handsFreeEnabled && isDictationMode
    }

    public mutating func consumeDelivery(
        wasDelivered: Bool,
        handsFreeEnabled: Bool,
        isDictationMode: Bool
    ) -> Bool {
        let shouldRearm = wasDelivered && shouldRearm(
            handsFreeEnabled: handsFreeEnabled,
            isDictationMode: isDictationMode
        )
        if !shouldRearm { disarm() }
        return shouldRearm
    }
}
