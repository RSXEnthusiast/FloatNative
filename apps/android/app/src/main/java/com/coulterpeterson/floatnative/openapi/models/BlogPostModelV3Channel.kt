/**
 *
 * NOTE: this file deviates from the OpenAPI generator output. The upstream
 * spec models `BlogPostModelV3.channel` as `oneOf: [ChannelModel | string]`
 * — Floatplane returns the full object on some endpoints and just the
 * channel-ID string on others. The Kotlin Moshi generator flattens that
 * into a single data class, which crashes on the string variant. The
 * post-codegen step in packages/openapi/scripts/generate-kotlin.sh
 * re-applies this hand-written sealed class after every regeneration.
 * iOS handles this natively as a Swift enum — see the parallel file at
 * apps/ios/FloatNative/Models/Generated/BlogPostModelV3Channel.swift.
 *
 * The Moshi JsonAdapter that decodes both variants lives at
 * apps/android/app/src/main/java/com/coulterpeterson/floatnative/utils/BlogPostModelV3ChannelAdapter.kt
 * and is registered in FloatplaneApi.init().
 */

@file:Suppress(
    "ArrayInDataClass",
    "EnumEntryName",
    "RemoveRedundantQualifierName",
    "UnusedImport"
)

package com.coulterpeterson.floatnative.openapi.models

import com.coulterpeterson.floatnative.openapi.models.ImageModel

sealed class BlogPostModelV3Channel {

    /** Floatplane returned a full ChannelModel object. */
    data class AsObject(val channel: ChannelModel) : BlogPostModelV3Channel()

    /** Floatplane returned only the channel ID as a string. */
    data class AsId(val id: kotlin.String) : BlogPostModelV3Channel()

    /** The channel ID, present in both variants. */
    val channelId: kotlin.String
        get() = when (this) {
            is AsObject -> channel.id
            is AsId -> id
        }

    /** The full channel object, or null if the response only carried the ID. */
    val channelObject: ChannelModel?
        get() = (this as? AsObject)?.channel

    // Convenience accessors that mirror the original data class shape so
    // existing call sites can stay terse. All return null when the response
    // only had the string ID — UI should fall back to creator info in that
    // case (most call sites already guard with `?:`).
    val title: kotlin.String? get() = channelObject?.title
    val icon: ImageModel? get() = channelObject?.icon
    val urlname: kotlin.String? get() = channelObject?.urlname
    val creator: kotlin.String? get() = channelObject?.creator
    val about: kotlin.String? get() = channelObject?.about
    val cover: ImageModel? get() = channelObject?.cover
    val card: ImageModel? get() = channelObject?.card
    val order: kotlin.Int? get() = channelObject?.order
    val socialLinks: kotlin.collections.Map<kotlin.String, java.net.URI>? get() = channelObject?.socialLinks
}
