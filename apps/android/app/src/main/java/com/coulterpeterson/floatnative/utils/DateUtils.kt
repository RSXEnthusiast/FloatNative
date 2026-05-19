package com.coulterpeterson.floatnative.utils

import android.text.format.DateUtils
import com.coulterpeterson.floatnative.openapi.models.PostMetadataModel
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * On a multi-video post (e.g. `C3GeAE0LmM`, videoCount=3) `videoDuration` is
 * the SUM of every video attachment, which made the card look like a 24-minute
 * video when the primary clip is actually 22 minutes (GH #29). Floatplane
 * returns `displayDuration` for that primary clip; prefer it, fall back to
 * videoDuration on legacy responses that don't carry the new field.
 */
val PostMetadataModel.preferredDisplayDuration: Long
    get() = displayDuration?.toLong() ?: videoDuration.toLong()

/**
 * Tail label appended to the duration on cards for posts that bundle extra
 * video parts (GH #23, #29). `videoCount=3` becomes `" +2"`. Empty string
 * for normal single-video posts.
 */
val PostMetadataModel.additionalPartsSuffix: String
    get() = videoCount?.takeIf { it > 1 }?.let { " +${it - 1}" } ?: ""

object DateUtils {
    fun getRelativeTime(isoString: String): String {
        try {
            // ISO 8601 format: 2023-10-27T10:00:00.000Z
            val parser = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
            parser.timeZone = TimeZone.getTimeZone("UTC")
            val date = parser.parse(isoString) ?: return ""
            val now = System.currentTimeMillis()
            
            return DateUtils.getRelativeTimeSpanString(
                date.time,
                now,
                DateUtils.MINUTE_IN_MILLIS,
                DateUtils.FORMAT_ABBREV_RELATIVE
            ).toString()
        } catch (e: Exception) {
            return ""
        }
    }

    fun formatDuration(seconds: Long): String {
        val hrs = seconds / 3600
        val mins = (seconds % 3600) / 60
        val secs = seconds % 60
        return if (hrs > 0) {
            String.format("%d:%02d:%02d", hrs, mins, secs)
        } else {
            String.format("%d:%02d", mins, secs)
        }
    }
}
