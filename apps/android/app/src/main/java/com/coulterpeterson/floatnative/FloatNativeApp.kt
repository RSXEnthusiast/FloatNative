package com.coulterpeterson.floatnative

import android.app.Application
import com.coulterpeterson.floatnative.api.FloatplaneApi

import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.disk.DiskCache
import coil.memory.MemoryCache
import coil.util.DebugLogger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

class FloatNativeApp : Application(), ImageLoaderFactory {

    override fun onCreate() {
        super.onCreate()

        // Initialize API Singleton
        FloatplaneApi.init(this)

        // CastReceiverContext initialization moved to TvMainActivity to ensure correct options loading
    }

    companion object {
        /// Application-lifetime scope for fire-and-forget background work
        /// that must outlive any single ViewModel — progress saves on
        /// navigation pop being the canonical case. Launching on the
        /// ViewModel's scope dropped the save with JobCancellationException
        /// the moment the user backed out of the player.
        val appScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }

    override fun newImageLoader(): ImageLoader {
        return ImageLoader.Builder(this)
            .memoryCache {
                MemoryCache.Builder(this)
                    .maxSizePercent(0.25)
                    .build()
            }
            .diskCache {
                DiskCache.Builder()
                    .directory(cacheDir.resolve("image_cache"))
                    .maxSizePercent(0.02) // Ignored if maxSize is set? Let's use fixed size to match iOS 200MB
                    .maxSizeBytes(200L * 1024 * 1024) // 200MB
                    .build()
            }
            .crossfade(true)
            .logger(DebugLogger())
            .build()
    }
}
