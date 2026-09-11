package com.shotclubhouse.sayso.settings

import android.content.SharedPreferences

/**
 * Minimal in-memory SharedPreferences so the real [Settings] can be exercised off-device.
 * Only the accessors [Settings] uses are implemented; the rest fail loudly if ever called.
 */
class FakeSharedPreferences(private val values: MutableMap<String, Any?> = mutableMapOf()) : SharedPreferences {

    val snapshot: Map<String, Any?> get() = values.toMap()

    override fun getAll(): MutableMap<String, *> = values

    override fun getString(key: String?, defValue: String?): String? = values[key] as? String ?: defValue

    override fun getInt(key: String?, defValue: Int): Int = values[key] as? Int ?: defValue

    override fun getLong(key: String?, defValue: Long): Long = values[key] as? Long ?: defValue

    override fun getFloat(key: String?, defValue: Float): Float = values[key] as? Float ?: defValue

    override fun getBoolean(key: String?, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue

    override fun contains(key: String?): Boolean = values.containsKey(key)

    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
        throw UnsupportedOperationException("Settings does not use string sets")

    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) =
        Unit

    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) =
        Unit

    override fun edit(): SharedPreferences.Editor = Editor()

    private inner class Editor : SharedPreferences.Editor {
        private val pending = mutableMapOf<String, Any?>()
        private val removals = mutableSetOf<String>()
        private var clear = false

        override fun putString(key: String, value: String?) = apply { pending[key] = value }
        override fun putInt(key: String, value: Int) = apply { pending[key] = value }
        override fun putLong(key: String, value: Long) = apply { pending[key] = value }
        override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
        override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
        override fun putStringSet(key: String, value: MutableSet<String>?) = apply { pending[key] = value }
        override fun remove(key: String) = apply { removals += key }
        override fun clear() = apply { clear = true }

        override fun commit(): Boolean {
            if (clear) values.clear()
            removals.forEach { values.remove(it) }
            values.putAll(pending)
            return true
        }

        override fun apply() {
            commit()
        }
    }
}
