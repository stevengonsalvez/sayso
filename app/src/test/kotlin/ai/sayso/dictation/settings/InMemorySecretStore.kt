package ai.sayso.dictation.settings

import ai.sayso.dictation.core.SecretStore

/** Test double for [SecretStore]; no Keystore, no Android. */
class InMemorySecretStore(initial: Map<String, String> = emptyMap()) : SecretStore {

    private val values = initial.toMutableMap()

    override fun get(providerId: String): String? = values[providerId]

    override fun set(providerId: String, value: String) {
        values[providerId] = value
    }

    override fun remove(providerId: String) {
        values.remove(providerId)
    }
}
