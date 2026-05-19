package com.coulterpeterson.floatnative.utils

import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import com.coulterpeterson.floatnative.openapi.models.ContentVideoV3ResponseTextTracksInner

/**
 * Build a Media3 [MediaItem] from a stream URL and the post's text tracks,
 * exposing them as out-of-band WebVTT subtitle renditions ExoPlayer will
 * surface through its standard CC picker (GH #11).
 *
 * Floatplane's `kind` field is `"captions"` for auto-generated tracks; we
 * map it to [C.ROLE_FLAG_SUBTITLE] so ExoPlayer treats it as a normal
 * subtitle track. The `src` field is a 15-minute R2 pre-signed URL — fine
 * because ExoPlayer fetches it during media prep.
 */
fun buildMediaItemWithSubtitles(
    videoUrl: String,
    textTracks: List<ContentVideoV3ResponseTextTracksInner>
): MediaItem {
    val builder = MediaItem.Builder().setUri(videoUrl)
    if (textTracks.isNotEmpty()) {
        val configs = textTracks
            .filter { !it.src.isNullOrBlank() }
            .map { track ->
                MediaItem.SubtitleConfiguration.Builder(android.net.Uri.parse(track.src))
                    .setMimeType(MimeTypes.TEXT_VTT)
                    .setLanguage(track.language ?: "en")
                    .setSelectionFlags(C.SELECTION_FLAG_DEFAULT.takeIf { track.generated != true } ?: 0)
                    .setRoleFlags(C.ROLE_FLAG_SUBTITLE)
                    .setLabel(if (track.generated == true) "Auto-generated" else null)
                    .build()
            }
        if (configs.isNotEmpty()) {
            builder.setSubtitleConfigurations(configs)
        }
    }
    return builder.build()
}
