package com.coulterpeterson.floatnative.utils

import android.content.Context
import com.squareup.moshi.JsonClass
import com.squareup.moshi.Moshi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Loads the bundled `whats_new.json` asset, decides whether to show the
 * popup for this launch, and persists the last-seen version so it doesn't
 * fire again until the next release.
 *
 * Mirrors apps/ios/FloatNative/Utilities/WhatsNewService.swift.
 * See #42 for the design notes (suppress on first install, show only
 * latest, Settings entry re-opens without mutating state).
 */
object WhatsNewRepository {

    @JsonClass(generateAdapter = true)
    data class Content(
        val version: String,
        val title: String,
        /**
         * Optional. Controls the value written to `lastSeenVersion` on a
         * first-ever launch. When set to an earlier release than [version],
         * the popup fires even for fresh installs — useful for the release
         * that *introduces* the What's New feature itself.
         */
        val firstLaunchSeed: String? = null,
        val items: List<Item>,
    )

    @JsonClass(generateAdapter = true)
    data class Item(
        val icon: String,
        val title: String,
        val body: String,
    )

    private const val PREFS = "whats_new"
    private const val KEY_LAST_SEEN_VERSION = "lastSeenVersion"
    private const val KEY_FIRST_LAUNCH_SEEDED = "firstLaunchSeeded"
    private const val ASSET_PATH = "whats_new.json"

    @Volatile private var cached: Content? = null

    private val _shouldShow = MutableStateFlow(false)
    val shouldShow: StateFlow<Boolean> = _shouldShow.asStateFlow()

    fun content(context: Context): Content? {
        cached?.let { return it }
        val parsed = try {
            val json = context.assets.open(ASSET_PATH).bufferedReader().use { it.readText() }
            // Use the app's shared Moshi (which registers KotlinJsonAdapterFactory).
            // A bare `Moshi.Builder().build()` can't reflect on Kotlin data classes
            // and silently returns null, which is what broke the "What's New"
            // button on Android.
            val adapter = buildAppMoshi().adapter(Content::class.java)
            adapter.fromJson(json)
        } catch (e: Exception) {
            DebugLogManager.other("Failed to parse whats_new.json", e.toString())
            null
        }
        cached = parsed
        return parsed
    }

    /** Call once from app launch. Sets [shouldShow] = true if there's something new. */
    fun presentIfNeeded(context: Context) {
        val content = content(context) ?: return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        if (!prefs.getBoolean(KEY_FIRST_LAUNCH_SEEDED, false)) {
            // First launch ever. Seed `lastSeen` with the JSON's
            // firstLaunchSeed (if specified) or the bundled version. When
            // the seed is an *earlier* version, the version-comparison
            // below will fire the popup even on a fresh install.
            prefs.edit()
                .putBoolean(KEY_FIRST_LAUNCH_SEEDED, true)
                .putString(KEY_LAST_SEEN_VERSION, content.firstLaunchSeed ?: content.version)
                .apply()
        }

        val lastSeen = prefs.getString(KEY_LAST_SEEN_VERSION, null)
        if (lastSeen != content.version) {
            _shouldShow.value = true
        }
    }

    /** Settings-triggered re-open. Doesn't touch lastSeen. */
    fun presentManually(context: Context) {
        if (content(context) != null) {
            _shouldShow.value = true
        }
    }

    /** Called by the dialog's Got It button. */
    fun dismiss(context: Context) {
        val content = content(context)
        if (content != null) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_LAST_SEEN_VERSION, content.version)
                .apply()
        }
        _shouldShow.value = false
    }
}
