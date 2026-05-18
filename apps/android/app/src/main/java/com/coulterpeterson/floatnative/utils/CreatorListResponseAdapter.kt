package com.coulterpeterson.floatnative.utils

import android.util.Log
import com.coulterpeterson.floatnative.openapi.models.BlogPostModelV3
import com.coulterpeterson.floatnative.openapi.models.ContentCreatorListLastItems
import com.coulterpeterson.floatnative.openapi.models.ContentCreatorListV3Response
import com.squareup.moshi.JsonAdapter
import com.squareup.moshi.JsonReader
import com.squareup.moshi.JsonWriter
import com.squareup.moshi.Moshi
import com.squareup.moshi.Types

/**
 * Element-tolerant decoder for the multi-creator feed response. A single
 * malformed BlogPostModelV3 (e.g. server sends an unknown post type, or a
 * field changes shape) is logged and skipped — the rest of the feed still
 * renders.
 *
 * Register on the Moshi builder before [com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory]
 * so this adapter wins for ContentCreatorListV3Response.
 */
class CreatorListResponseAdapter(
    private val blogPostAdapter: JsonAdapter<BlogPostModelV3>,
    private val cursorAdapter: JsonAdapter<List<ContentCreatorListLastItems>>,
) : JsonAdapter<ContentCreatorListV3Response>() {

    private val keys = JsonReader.Options.of("blogPosts", "lastElements")

    override fun fromJson(reader: JsonReader): ContentCreatorListV3Response {
        var blogPosts: List<BlogPostModelV3> = emptyList()
        var lastElements: List<ContentCreatorListLastItems> = emptyList()

        reader.beginObject()
        while (reader.hasNext()) {
            when (reader.selectName(keys)) {
                0 -> blogPosts = readLossyArray(reader)
                1 -> lastElements = cursorAdapter.fromJson(reader) ?: emptyList()
                else -> {
                    reader.skipName()
                    reader.skipValue()
                }
            }
        }
        reader.endObject()

        return ContentCreatorListV3Response(
            blogPosts = blogPosts,
            lastElements = lastElements,
        )
    }

    private fun readLossyArray(reader: JsonReader): List<BlogPostModelV3> {
        if (reader.peek() == JsonReader.Token.NULL) {
            reader.nextNull<Any>()
            return emptyList()
        }
        val result = mutableListOf<BlogPostModelV3>()
        reader.beginArray()
        var index = 0
        while (reader.hasNext()) {
            val peek = reader.peekJson()
            try {
                val value = blogPostAdapter.fromJson(peek)
                if (value != null) result.add(value)
            } catch (e: Exception) {
                val msg = "${e.javaClass.simpleName}: ${e.message}"
                Log.w("CreatorListResponse", "skipped post at index $index: $msg")
                DebugLogManager.decode("Feed: skipped post at index $index", msg)
            } finally {
                peek.close()
                reader.skipValue()
            }
            index += 1
        }
        reader.endArray()
        return result
    }

    override fun toJson(writer: JsonWriter, value: ContentCreatorListV3Response?) {
        if (value == null) {
            writer.nullValue()
            return
        }
        writer.beginObject()
        writer.name("blogPosts")
        writer.beginArray()
        for (post in value.blogPosts) {
            blogPostAdapter.toJson(writer, post)
        }
        writer.endArray()
        writer.name("lastElements")
        cursorAdapter.toJson(writer, value.lastElements)
        writer.endObject()
    }

    class Factory : JsonAdapter.Factory {
        override fun create(
            type: java.lang.reflect.Type,
            annotations: MutableSet<out Annotation>,
            moshi: Moshi
        ): JsonAdapter<*>? {
            if (annotations.isNotEmpty()) return null
            // Use raw-type comparison so this still matches if Moshi wraps the
            // Type in a ParameterizedType internally.
            if (Types.getRawType(type) != ContentCreatorListV3Response::class.java) return null
            val blogPostAdapter = moshi.adapter(BlogPostModelV3::class.java)
            val listType = Types.newParameterizedType(
                List::class.java, ContentCreatorListLastItems::class.java
            )
            val cursorAdapter: JsonAdapter<List<ContentCreatorListLastItems>> =
                moshi.adapter(listType)
            return CreatorListResponseAdapter(blogPostAdapter, cursorAdapter)
        }
    }
}
