package com.coulterpeterson.floatnative.utils

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.text.SimpleDateFormat
import java.time.Instant
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * In-memory ring buffer of recent diagnostic events. Surfaced from
 * Settings → Debug Log so users can paste the contents straight into a
 * GitHub issue. Bounded; nothing is persisted to disk.
 *
 * Thread-safe — `append` is callable from any thread (interceptors,
 * Moshi adapters running on Retrofit's worker pool, etc.). Compose
 * collects the [entries] StateFlow on the main thread.
 *
 * Mirrors apps/ios/FloatNative/Utilities/DebugLogManager.swift.
 */
object DebugLogManager {

    enum class Category { API, DECODE, AUTH, OTHER }

    data class Entry(
        val id: String,
        val timestamp: Instant,
        val category: Category,
        val message: String,
        val detail: String?,
    )

    private const val LIMIT = 200
    private val lock = ReentrantLock()
    private val storage = ArrayDeque<Entry>(LIMIT)

    private val _entries = MutableStateFlow<List<Entry>>(emptyList())
    val entries: StateFlow<List<Entry>> = _entries.asStateFlow()

    fun append(entry: Entry) {
        val snapshot = lock.withLock {
            storage.addFirst(entry)
            while (storage.size > LIMIT) storage.removeLast()
            storage.toList()
        }
        _entries.value = snapshot
    }

    fun api(message: String, detail: String? = null) {
        append(Entry(UUID.randomUUID().toString(), Instant.now(), Category.API, message, detail))
    }

    fun decode(message: String, detail: String? = null) {
        append(Entry(UUID.randomUUID().toString(), Instant.now(), Category.DECODE, message, detail))
    }

    fun auth(message: String, detail: String? = null) {
        append(Entry(UUID.randomUUID().toString(), Instant.now(), Category.AUTH, message, detail))
    }

    fun other(message: String, detail: String? = null) {
        append(Entry(UUID.randomUUID().toString(), Instant.now(), Category.OTHER, message, detail))
    }

    fun clear() {
        lock.withLock { storage.clear() }
        _entries.value = emptyList()
    }

    /**
     * Render the buffer as a single block of text suitable for emailing or
     * pasting into a bug report.
     */
    fun exportText(): String {
        val snapshot = lock.withLock { storage.toList() }
        val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US)
        return snapshot.joinToString("\n\n") { entry ->
            buildString {
                append("[").append(formatter.format(Date.from(entry.timestamp))).append("] ")
                append("[").append(entry.category.name.lowercase()).append("] ")
                append(entry.message)
                entry.detail?.takeIf { it.isNotEmpty() }?.let {
                    append("\n").append(it)
                }
            }
        }
    }
}
