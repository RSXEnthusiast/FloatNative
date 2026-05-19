package com.coulterpeterson.floatnative

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.lifecycle.lifecycleScope
import com.coulterpeterson.floatnative.ui.screens.auth.LoginScreen
import com.coulterpeterson.floatnative.ui.theme.FloatNativeTheme
import com.coulterpeterson.floatnative.ui.navigation.AppNavigation
import kotlinx.coroutines.launch
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect

val LocalPipMode = compositionLocalOf { false }

class MainActivity : AppCompatActivity() {
    private var isInPipMode by mutableStateOf(false)
    var pipParams: android.app.PictureInPictureParams.Builder? = null
    var isVideoPlaying: Boolean = false
    /**
     * Aspect ratio of the *currently loaded* video, set by VideoPlayerScreen's
     * Player.Listener.onVideoSizeChanged. Null until the player has resolved
     * the video dimensions, and cleared when the player screen disposes or
     * loads a different video — so we never carry a stale ratio from the
     * previous video into a new PiP entry. This is what fixed GH #41: before,
     * `pipParams` was either stale or unset when the user pressed Home before
     * ExoPlayer reported the size, and PiP entered at 16:9 with a broken
     * layout that only a manual resize would un-stick.
     */
    var currentVideoRatio: android.util.Rational? = null

    fun updatePipParams(aspectRatio: android.util.Rational?) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            val ratio = aspectRatio ?: android.util.Rational(16, 9)
            val builder = android.app.PictureInPictureParams.Builder()
                .setAspectRatio(ratio)
            pipParams = builder
            // setPictureInPictureParams is safe both before and during PiP;
            // during PiP it live-updates the window's aspect ratio, which is
            // why the size listener calling this from a running PiP session
            // typically corrects the layout on its own.
            setPictureInPictureParams(builder.build())
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Removed static enableEdgeToEdge() here to call it dynamically below
        
        setContent {
            val context = androidx.compose.ui.platform.LocalContext.current
            
            // Observe theme changes from TokenManager flow
            val themeMode by com.coulterpeterson.floatnative.api.FloatplaneApi.tokenManager.themeFlow.collectAsState(initial = "dark")
            
            val isDarkTheme = when (themeMode) {
                "light" -> false
                "dark" -> true
                else -> androidx.compose.foundation.isSystemInDarkTheme()
            }
            
            LaunchedEffect(isDarkTheme) {
                 enableEdgeToEdge(
                    statusBarStyle = androidx.activity.SystemBarStyle.auto(
                        android.graphics.Color.TRANSPARENT,
                        android.graphics.Color.TRANSPARENT,
                    ) { isDarkTheme },
                    navigationBarStyle = androidx.activity.SystemBarStyle.auto(
                        android.graphics.Color.TRANSPARENT,
                        android.graphics.Color.TRANSPARENT,
                    ) { isDarkTheme }
                )
            }

            FloatNativeTheme(darkTheme = isDarkTheme) {
                CompositionLocalProvider(LocalPipMode provides isInPipMode) {
                    Surface(
                        modifier = Modifier.fillMaxSize(),
                        color = MaterialTheme.colorScheme.background
                    ) {
                        // Phone navigation
                        val startDestination = androidx.compose.runtime.remember(Unit) {
                            val initialToken = com.coulterpeterson.floatnative.api.FloatplaneApi.tokenManager.accessToken
                            if (!initialToken.isNullOrEmpty()) {
                                "home"
                            } else {
                                "login"
                            }
                        }
                        AppNavigation(startDestination = startDestination)
                    }
                }
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            val ratio = currentVideoRatio
            // Skip PiP entry when we haven't yet resolved the current video's
            // aspect ratio (GH #41). Entering with a stale or hardcoded 16:9
            // produced a broken layout that the user could only fix by
            // resizing the PiP window.
            if (isVideoPlaying && ratio != null) {
                val params = (pipParams ?: android.app.PictureInPictureParams.Builder()
                    .setAspectRatio(ratio))
                    .build()
                // Pre-flip isInPipMode BEFORE calling Android's PiP entry
                // because `onPictureInPictureModeChanged(true)` is delivered
                // ~700ms after the activity is already resized into the PiP
                // window (confirmed via PiPDebug logs). Until that callback
                // fires Compose still thinks we're in portrait, and renders
                // the full portrait layout into the PiP window — that's the
                // "video stuck in the top-left of the mini-player" report.
                // onResume rolls this back if PiP never actually engages.
                isInPipMode = true
                enterPictureInPictureMode(params)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Defensive rollback for the pre-flip in onUserLeaveHint — if PiP
        // never actually started (e.g. Android refused entry, or the user
        // returned before the transition completed), we shouldn't be stuck
        // rendering the fullscreen-PiP layout in a regular activity.
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
            if (isInPipMode && !isInPictureInPictureMode) {
                isInPipMode = false
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        isInPipMode = isInPictureInPictureMode
    }
    
    override fun onNewIntent(intent: android.content.Intent?) {
        super.onNewIntent(intent)
        handleDeepLink(intent)
    }
    
    private fun handleDeepLink(intent: android.content.Intent?) {
        val data = intent?.data
        if (data != null && data.scheme == "floatnative" && data.host == "auth") {
             val code = data.getQueryParameter("code")
             if (code != null) {
                 // Emit to global flow
                 lifecycleScope.launch {
                     com.coulterpeterson.floatnative.api.FloatplaneApi.authCodeFlow.emit(code)
                 }
             }
        }
    }
}