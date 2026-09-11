package com.shotclubhouse.sayso.settings

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import com.shotclubhouse.sayso.core.SecretStore
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * API keys stored in SharedPreferences, encrypted with an AES-256-GCM key that never
 * leaves the Android Keystore. Each value is stored as base64(iv || ciphertext+tag).
 *
 * Every operation is best-effort: a wiped or unavailable Keystore makes stored keys
 * unreadable, which must degrade to "no key saved" rather than crash dictation.
 */
class KeystoreSecretStore(private val prefs: SharedPreferences) : SecretStore {

    constructor(context: Context) : this(
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE),
    )

    override fun get(providerId: String): String? {
        val stored = prefs.getString(providerId, null) ?: return null
        return try {
            val blob = Base64.getDecoder().decode(stored)
            if (blob.size <= IV_BYTES) return null
            val cipher = Cipher.getInstance(TRANSFORMATION).apply {
                init(
                    Cipher.DECRYPT_MODE,
                    secretKey(),
                    GCMParameterSpec(TAG_BITS, blob, 0, IV_BYTES),
                )
                // Binds the blob to its slot: a value copied between providers will not decrypt.
                updateAAD(providerId.toByteArray(Charsets.UTF_8))
            }
            String(cipher.doFinal(blob, IV_BYTES, blob.size - IV_BYTES), Charsets.UTF_8)
        } catch (e: GeneralSecurityException) {
            Log.w(TAG, "Could not decrypt secret for $providerId", e)
            null
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Corrupt secret for $providerId", e)
            null
        } catch (e: RuntimeException) {
            Log.w(TAG, "Keystore unavailable while reading $providerId", e)
            null
        }
    }

    override fun set(providerId: String, value: String) {
        val encrypted = try {
            val cipher = Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.ENCRYPT_MODE, secretKey())
                updateAAD(providerId.toByteArray(Charsets.UTF_8))
            }
            val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            Base64.getEncoder().encodeToString(cipher.iv + ciphertext)
        } catch (e: GeneralSecurityException) {
            Log.e(TAG, "Could not encrypt secret for $providerId", e)
            null
        } catch (e: RuntimeException) {
            Log.e(TAG, "Keystore unavailable while writing $providerId", e)
            null
        }

        // Storing the key in the clear is not an option, so a failed write clears the slot.
        val editor = prefs.edit()
        if (encrypted == null) editor.remove(providerId) else editor.putString(providerId, encrypted)
        editor.apply()
    }

    override fun remove(providerId: String) {
        prefs.edit().remove(providerId).apply()
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(KEY_BITS)
                .build(),
        )
        return generator.generateKey()
    }

    companion object {
        const val PREFS_NAME = "sayso_secrets"
        const val KEY_ALIAS = "sayso.secrets"

        private const val TAG = "SaysoSecrets"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val KEY_BITS = 256
        private const val IV_BYTES = 12
        private const val TAG_BITS = 128
    }
}
