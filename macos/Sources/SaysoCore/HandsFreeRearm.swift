public enum HandsFreeRearmPolicy {
    public static func shouldRearm(
        isArmed: Bool,
        handsFreeEnabled: Bool,
        isDictationMode: Bool
    ) -> Bool {
        isArmed && handsFreeEnabled && isDictationMode
    }
}
