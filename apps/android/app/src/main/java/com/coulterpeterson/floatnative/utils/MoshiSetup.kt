package com.coulterpeterson.floatnative.utils

import com.coulterpeterson.floatnative.openapi.infrastructure.ByteArrayAdapter
import com.coulterpeterson.floatnative.openapi.infrastructure.BigDecimalAdapter
import com.coulterpeterson.floatnative.openapi.infrastructure.BigIntegerAdapter
import com.coulterpeterson.floatnative.openapi.infrastructure.LocalDateAdapter
import com.coulterpeterson.floatnative.openapi.infrastructure.LocalDateTimeAdapter
import com.coulterpeterson.floatnative.openapi.infrastructure.OffsetDateTimeAdapter
import com.coulterpeterson.floatnative.openapi.infrastructure.URIAdapter
import com.coulterpeterson.floatnative.openapi.infrastructure.UUIDAdapter
import com.squareup.moshi.Moshi
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory

/**
 * Builds the Moshi instance used by every API call. Custom type adapters
 * (BlogPostModelV3Channel, ContentCreatorListV3Response, @Lossy lists) are
 * registered BEFORE [KotlinJsonAdapterFactory] so they win the type lookup —
 * Moshi consults factories in registration order and KotlinJsonAdapterFactory
 * is greedy enough to match a sealed class and then fail at runtime.
 *
 * Mirror this setup in tests so production and tests decode the same way.
 */
fun buildAppMoshi(): Moshi = Moshi.Builder()
    // Type-specific adapters that must beat KotlinJsonAdapter.
    .add(BlogPostModelV3ChannelAdapter.Factory())
    .add(CreatorListResponseAdapter.Factory())
    .add(LossyListAdapterFactory())
    // Same scalar/date adapters the openapi-generated Serializer uses,
    // duplicated here so we can control where KotlinJsonAdapter sits in the
    // chain. See packages/openapi/scripts/generate-kotlin.sh — we don't edit
    // Serializer.kt because it gets regenerated.
    .add(OffsetDateTimeAdapter())
    .add(LocalDateTimeAdapter())
    .add(LocalDateAdapter())
    .add(UUIDAdapter())
    .add(ByteArrayAdapter())
    .add(URIAdapter())
    .add(KotlinJsonAdapterFactory())
    .add(BigDecimalAdapter())
    .add(BigIntegerAdapter())
    .build()
