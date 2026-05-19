package com.coulterpeterson.floatnative.utils

import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Sleep timer for late-night WAN-Show listeners. Once armed, counts down
 * the chosen duration and then asks the player ViewModel to pause. Resets
 * on cold launch. Mirrors apps/ios/FloatNative/Utilities/SleepTimerService.swift.
 *
 * The pause action is delivered via [onExpire] — the caller (e.g. the
 * active ViewModel) registers a listener so the repository stays
 * decoupled from any one player. See #31.
 */
object SleepTimerRepository {

    /** Picker options offered in Settings (in seconds). */
    val options: List<Long> = listOf(15L, 30L, 45L, 60L, 90L, 120L).map { it * 60L }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var job: Job? = null
    private val onExpireListeners = mutableSetOf<() -> Unit>()

    private val _remainingSeconds = MutableStateFlow<Int?>(null)
    val remainingSeconds: StateFlow<Int?> = _remainingSeconds.asStateFlow()

    val isActive: Boolean get() = _remainingSeconds.value != null

    /** Listener fires on the main thread when the timer expires. */
    fun setOnExpireListener(listener: () -> Unit) {
        onExpireListeners.add(listener)
    }

    fun removeOnExpireListener(listener: () -> Unit) {
        onExpireListeners.remove(listener)
    }

    fun arm(durationSeconds: Long) {
        cancel()
        val endRealtimeMillis = SystemClock.elapsedRealtime() + durationSeconds * 1_000L
        _remainingSeconds.value = durationSeconds.toInt()
        job = scope.launch {
            while (true) {
                val remainingMs = endRealtimeMillis - SystemClock.elapsedRealtime()
                if (remainingMs <= 0) {
                    _remainingSeconds.value = null
                    onExpireListeners.toList().forEach { it.invoke() }
                    break
                }
                _remainingSeconds.value = ((remainingMs + 999) / 1_000L).toInt()
                delay(1_000L)
            }
        }
    }

    fun cancel() {
        job?.cancel()
        job = null
        _remainingSeconds.value = null
    }

    fun formatRemaining(seconds: Int): String {
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
    }

    fun formatDuration(seconds: Long): String {
        val totalMinutes = (seconds / 60).toInt()
        if (totalMinutes >= 60) {
            val hours = totalMinutes / 60.0
            return if (hours == hours.toInt().toDouble()) "${hours.toInt()} hr"
            else "%.1f hr".format(hours)
        }
        return "$totalMinutes min"
    }
}
