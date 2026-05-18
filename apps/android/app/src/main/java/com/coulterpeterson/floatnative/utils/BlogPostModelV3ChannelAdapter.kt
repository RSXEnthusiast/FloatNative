package com.coulterpeterson.floatnative.utils

import com.coulterpeterson.floatnative.openapi.models.BlogPostModelV3Channel
import com.coulterpeterson.floatnative.openapi.models.ChannelModel
import com.squareup.moshi.JsonAdapter
import com.squareup.moshi.JsonDataException
import com.squareup.moshi.JsonReader
import com.squareup.moshi.JsonWriter
import com.squareup.moshi.Moshi
import java.lang.reflect.Type

/**
 * Decodes [BlogPostModelV3Channel], a `oneOf [ChannelModel | string]` from the
 * Floatplane spec. Peeks the next JSON token: an object ⇒ [BlogPostModelV3Channel.AsObject],
 * a string ⇒ [BlogPostModelV3Channel.AsId]. Anything else surfaces as
 * `JsonDataException` (which the surrounding LossyListAdapter will catch and
 * log, dropping the offending post).
 *
 * Why this exists: the Kotlin Moshi codegen flattened the oneOf into a single
 * required-field data class, so a real-world response with `"channel": "<id>"`
 * crashed the home feed. iOS's Swift codegen handled this natively as an enum
 * — this adapter brings Android to parity.
 */
class BlogPostModelV3ChannelAdapter(
    private val channelAdapter: JsonAdapter<ChannelModel>,
) : JsonAdapter<BlogPostModelV3Channel>() {

    override fun fromJson(reader: JsonReader): BlogPostModelV3Channel? {
        return when (val token = reader.peek()) {
            JsonReader.Token.NULL -> {
                reader.nextNull<Any>()
                null
            }
            JsonReader.Token.STRING -> BlogPostModelV3Channel.AsId(reader.nextString())
            JsonReader.Token.BEGIN_OBJECT -> {
                val channel = channelAdapter.fromJson(reader)
                    ?: throw JsonDataException(
                        "Expected ChannelModel object for BlogPostModelV3Channel at ${reader.path}"
                    )
                BlogPostModelV3Channel.AsObject(channel)
            }
            else -> throw JsonDataException(
                "Expected STRING or BEGIN_OBJECT for BlogPostModelV3Channel, got $token at ${reader.path}"
            )
        }
    }

    override fun toJson(writer: JsonWriter, value: BlogPostModelV3Channel?) {
        when (value) {
            null -> writer.nullValue()
            is BlogPostModelV3Channel.AsId -> writer.value(value.id)
            is BlogPostModelV3Channel.AsObject -> channelAdapter.toJson(writer, value.channel)
        }
    }

    class Factory : JsonAdapter.Factory {
        override fun create(
            type: Type,
            annotations: MutableSet<out Annotation>,
            moshi: Moshi
        ): JsonAdapter<*>? {
            if (annotations.isNotEmpty()) return null
            // Match the sealed-class type exactly (subclasses are decoded via the
            // sealed class, never directly).
            if (type !== BlogPostModelV3Channel::class.java) return null
            val channelAdapter = moshi.adapter(ChannelModel::class.java)
            return BlogPostModelV3ChannelAdapter(channelAdapter)
        }
    }
}
