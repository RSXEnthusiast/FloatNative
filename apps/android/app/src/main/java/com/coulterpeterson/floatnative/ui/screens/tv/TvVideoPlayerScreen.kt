@file:OptIn(androidx.tv.material3.ExperimentalTvMaterial3Api::class)

package com.coulterpeterson.floatnative.ui.screens.tv

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight

import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.PlayerView
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.ListItem
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.coulterpeterson.floatnative.viewmodels.VideoPlayerState
import com.coulterpeterson.floatnative.viewmodels.VideoPlayerViewModel
import androidx.compose.ui.layout.ContentScale
import androidx.tv.material3.IconButton
import androidx.tv.material3.Icon
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ThumbUp
import androidx.compose.material.icons.filled.ThumbDown
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.clip
import coil.compose.AsyncImage
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxWidth
import com.coulterpeterson.floatnative.utils.orderedVideoAttachments

@androidx.annotation.OptIn(UnstableApi::class)
@kotlin.OptIn(ExperimentalTvMaterial3Api::class)
@Composable
fun TvVideoPlayerScreen(
    videoId: String,
    onBack: () -> Unit,
    startTimestamp: Long = 0L,
    viewModel: VideoPlayerViewModel = viewModel()
) {
    val state by viewModel.state.collectAsState()
    val sidebarMode by viewModel.sidebarMode.collectAsState()
    val captionsEnabled by viewModel.captionsEnabled.collectAsState()
    
    // ExoPlayer instance from ViewModel
    val exoPlayer = viewModel.player
    val context = LocalContext.current
    val lifecycleOwner = androidx.compose.ui.platform.LocalLifecycleOwner.current

    LaunchedEffect(videoId) {
        viewModel.loadVideo(videoId)
    }

    // The ViewModel emits a PlayerAction.Seek when it loads the saved
    // resume position from /api/v3/content/video/{id}. The phone screen
    // listens for this; the TV screen didn't, so resuming from history
    // (or any other entry point) silently started from 0 (GH #20).
    LaunchedEffect(Unit) {
        viewModel.playerAction.collect { action ->
            when (action) {
                is com.coulterpeterson.floatnative.viewmodels.PlayerAction.Seek -> {
                    exoPlayer.seekTo(action.position)
                    exoPlayer.play()
                }
            }
        }
    }

    // Initial Seek for Cast Resume
    var hasPerformedInitialSeek by remember(videoId) { mutableStateOf(false) }

    // Handle Player state updates
    LaunchedEffect(state) {
        if (state is VideoPlayerState.Content) {
            val contentState = state as VideoPlayerState.Content
            if (contentState.videoUrl != null) {
                val currentItem = exoPlayer.currentMediaItem
                val currentUri = currentItem?.localConfiguration?.uri?.toString()
                val currentSubsCount = currentItem?.localConfiguration?.subtitleConfigurations?.size ?: 0
                val urlChanged = currentUri == null || currentUri != contentState.videoUrl
                val subsChanged = currentSubsCount != contentState.textTracks.size

                if (urlChanged || subsChanged) {
                    val resumePosition = if (urlChanged) 0L else exoPlayer.currentPosition
                    val mediaItem = com.coulterpeterson.floatnative.utils.buildMediaItemWithSubtitles(
                        videoUrl = contentState.videoUrl,
                        textTracks = contentState.textTracks
                    )
                    exoPlayer.setMediaItem(mediaItem, resumePosition)
                    exoPlayer.prepare()
                    // Sync the captions-enabled flow now that a track is
                    // wired up. The phone uses Media3's built-in CC button
                    // which manages this state on its own — TV reads our
                    // flow to tint the btn_subtitles icon.
                    viewModel.syncCaptionsEnabledFromTrackSelector()
                    
                    if (startTimestamp > 0 && !hasPerformedInitialSeek) {
                        exoPlayer.seekTo(startTimestamp)
                        hasPerformedInitialSeek = true
                    }
                    
                    exoPlayer.play() 
                } else if (startTimestamp > 0 && !hasPerformedInitialSeek) {
                     exoPlayer.seekTo(startTimestamp)
                     hasPerformedInitialSeek = true
                }
            } else {
                 exoPlayer.stop()
                 exoPlayer.clearMediaItems()
            }
        }
    }
    
    // Clean up only when leaving the screen completely (handled by ViewModel usually, but stop on dispose here for TV nav)
    DisposableEffect(Unit) {
        onDispose {
            exoPlayer.pause()
            viewModel.saveWatchProgress()
        }
    }

    // Sleep timer — pause this player when the timer expires.
    DisposableEffect(exoPlayer) {
        val listener: () -> Unit = { exoPlayer.pause() }
        com.coulterpeterson.floatnative.utils.SleepTimerRepository.setOnExpireListener(listener)
        onDispose {
            com.coulterpeterson.floatnative.utils.SleepTimerRepository.removeOnExpireListener(listener)
        }
    }

    // Handle App Lifecycle (Backgrounding)
    DisposableEffect(lifecycleOwner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_STOP) {
                viewModel.saveWatchProgress()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    // Sidebar State already collected above

    Row(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
    ) {
        // Video Player Container
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight(),
            contentAlignment = Alignment.Center
        ) {
            when (state) {
                is VideoPlayerState.Loading, VideoPlayerState.Idle -> {
                    Text("Loading Video...", color = Color.White)
                }
                is VideoPlayerState.Error -> {
                    Text(
                        text = "Error: ${(state as VideoPlayerState.Error).message}",
                        color = MaterialTheme.colorScheme.error
                    )
                }
                is VideoPlayerState.Content -> {
                    val contentState = state as VideoPlayerState.Content
                    
                    if (contentState.videoUrl != null) {
                        // Video Player Layout
                        var showSettings by remember { mutableStateOf(false) }
    
                        AndroidView(
                            factory = { ctx ->
                                // Inflate the wrapper layout which sets the custom controller attribute
                                val view = android.view.LayoutInflater.from(ctx).inflate(
                                    com.coulterpeterson.floatnative.R.layout.tv_player_wrapper, 
                                    null
                                ) as PlayerView
                                
                                view.apply {
                                    player = exoPlayer
                                    keepScreenOn = true  // prevent sleep while the player is visible (Android TV / Fire TV)
                                    // XML sets resize_mode="fit", show_buffering="always", etc.

                                    // Handle D-pad wakeup using KeyListener instead of overriding dispatchKeyEvent
                                    setOnKeyListener { _, keyCode, event ->
                                        if (event.action == android.view.KeyEvent.ACTION_DOWN && !isControllerFullyVisible) {
                                            when (keyCode) {
                                                android.view.KeyEvent.KEYCODE_DPAD_CENTER,
                                                android.view.KeyEvent.KEYCODE_ENTER,
                                                android.view.KeyEvent.KEYCODE_DPAD_UP,
                                                android.view.KeyEvent.KEYCODE_DPAD_DOWN,
                                                android.view.KeyEvent.KEYCODE_DPAD_LEFT,
                                                android.view.KeyEvent.KEYCODE_DPAD_RIGHT -> {
                                                    showController()
                                                    return@setOnKeyListener true
                                                }
                                            }
                                        }
                                        false
                                    }
    
                                    setControllerVisibilityListener(androidx.media3.ui.PlayerView.ControllerVisibilityListener { visibility ->
                                        if (visibility == android.view.View.GONE && sidebarMode == com.coulterpeterson.floatnative.viewmodels.PlayerSidebarMode.None) {
                                          requestFocus()
                                        }
                                    })
    
                                    // Ensure the view takes focus to handle D-pad events
                                    descendantFocusability = ViewGroup.FOCUS_AFTER_DESCENDANTS
                                    requestFocus()
                                }
                            },
                            update = { playerView ->
                                // Bind Custom Controls
                                val btnLike = playerView.findViewById<android.widget.ImageButton>(com.coulterpeterson.floatnative.R.id.btn_like)
                                val btnDislike = playerView.findViewById<android.widget.ImageButton>(com.coulterpeterson.floatnative.R.id.btn_dislike)
                                val btnDesc = playerView.findViewById<android.widget.ImageButton>(com.coulterpeterson.floatnative.R.id.btn_description)
                                val btnComments = playerView.findViewById<android.widget.ImageButton>(com.coulterpeterson.floatnative.R.id.btn_comments)
                                val btnSubtitles = playerView.findViewById<android.widget.ImageButton>(com.coulterpeterson.floatnative.R.id.btn_subtitles)
                                val btnParts = playerView.findViewById<android.widget.ImageButton>(com.coulterpeterson.floatnative.R.id.btn_parts)
                                val btnSettings = playerView.findViewById<android.widget.ImageButton>(com.coulterpeterson.floatnative.R.id.btn_settings)
    
                                // Update UI State (Colors)
                                val redColor = android.graphics.Color.RED
                                val whiteColor = android.graphics.Color.WHITE
                                val grayColor = android.graphics.Color.LTGRAY
    
                                val interaction = (state as? VideoPlayerState.Content)?.userInteraction
                                
                                btnLike?.setColorFilter(if (interaction == com.coulterpeterson.floatnative.openapi.models.ContentPostV3Response.UserInteraction.like) 
                                    redColor else whiteColor)
                                
                                btnDislike?.setColorFilter(if (interaction == com.coulterpeterson.floatnative.openapi.models.ContentPostV3Response.UserInteraction.dislike) 
                                    redColor else whiteColor)
    
                                // Set Listeners
                                btnLike?.setOnClickListener { viewModel.toggleLike() }
                                btnDislike?.setOnClickListener { viewModel.toggleDislike() }
                                
                                btnDesc?.setOnClickListener { 
                                    viewModel.openDescription()
                                }
                                btnComments?.setOnClickListener {
                                    viewModel.openComments()
                                }

                                // Subtitles button (GH #11) — only visible when
                                // the loaded video ships caption cues. Tint
                                // flips when captions are enabled, same
                                // pattern as the like/dislike buttons.
                                val hasCaptions = (state as? VideoPlayerState.Content)
                                    ?.textTracks
                                    ?.isNotEmpty() == true
                                btnSubtitles?.visibility = if (hasCaptions) android.view.View.VISIBLE else android.view.View.GONE
                                btnSubtitles?.setColorFilter(
                                    if (captionsEnabled) android.graphics.Color.parseColor("#3FA9F5") else whiteColor
                                )
                                btnSubtitles?.setOnClickListener { viewModel.toggleCaptions() }

                                // Parts button (GH #23) — only visible for
                                // posts with more than one video attachment.
                                val partsCount = (state as? VideoPlayerState.Content)
                                    ?.blogPost
                                    ?.videoAttachments
                                    ?.size ?: 0
                                btnParts?.visibility = if (partsCount > 1) android.view.View.VISIBLE else android.view.View.GONE
                                btnParts?.setOnClickListener {
                                    viewModel.openParts()
                                }

                                 btnSettings?.setOnClickListener {
                                    showSettings = true
                                }
                            },
                            modifier = Modifier.fillMaxSize()
                        )
                        
                        if (showSettings) {
                           val contentState = state as VideoPlayerState.Content
                           Dialog(onDismissRequest = { showSettings = false }) {
                               Box(
                                   modifier = Modifier
                                       .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(12.dp))
                                       .padding(16.dp)
                                       .width(300.dp)
                               ) {
                                   Column {
                                       Text("Quality", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(bottom = 8.dp))
                                       LazyColumn {
                                           items(contentState.availableQualities.size) { index ->
                                               val quality = contentState.availableQualities[index]
                                               val isSelected = quality == contentState.currentQuality
                                               ListItem(
                                                   selected = isSelected,
                                                   onClick = {
                                                       viewModel.changeQuality(quality)
                                                       showSettings = false
                                                   },
                                                   headlineContent = { Text(quality.label) }
                                               )
                                           }
                                       }
                                   }
                               }
                           }
                        }
                    } else {
                        // Non-Video Layout (Text/Image)
                        LazyColumn(
                            modifier = Modifier.fillMaxSize()
                        ) {
                            // 1. Thumbnail
                            if (contentState.blogPost.thumbnail != null) {
                                item {
                                    AsyncImage(
                                        model = contentState.blogPost.thumbnail.path.toString(),
                                        contentDescription = contentState.blogPost.title,
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .height(300.dp),
                                        contentScale = ContentScale.Crop
                                    )
                                }
                            }
                            
                            // 2. Info Row
                            item {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(16.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(16.dp)
                                ) {
                                    // Channel Icon
                                    val channelIcon = contentState.blogPost.channel.icon?.childImages?.firstOrNull()?.path 
                                        ?: contentState.blogPost.channel.icon?.path
                                        
                                    AsyncImage(
                                        model = channelIcon?.toString(),
                                        contentDescription = contentState.blogPost.channel.title,
                                        modifier = Modifier
                                            .size(48.dp)
                                            .clip(CircleShape),
                                        contentScale = ContentScale.Crop
                                    )
                                    
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(
                                            text = contentState.blogPost.title,
                                            style = MaterialTheme.typography.titleLarge
                                        )
                                        Text(
                                            text = contentState.blogPost.channel.title,
                                            style = MaterialTheme.typography.bodyMedium,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant
                                        )
                                    }
                                    
                                    // Like Button
                                    val interaction = contentState.userInteraction
                                    IconButton(onClick = { viewModel.toggleLike() }) {
                                        Icon(
                                            imageVector = Icons.Default.ThumbUp,
                                            contentDescription = "Like",
                                            tint = if (interaction == com.coulterpeterson.floatnative.openapi.models.ContentPostV3Response.UserInteraction.like) 
                                                Color.Red else MaterialTheme.colorScheme.onSurface 
                                        )
                                    }
                                    
                                     // Dislike Button
                                    IconButton(onClick = { viewModel.toggleDislike() }) {
                                        Icon(
                                            imageVector = Icons.Default.ThumbDown,
                                            contentDescription = "Dislike",
                                            tint = if (interaction == com.coulterpeterson.floatnative.openapi.models.ContentPostV3Response.UserInteraction.dislike) 
                                                Color.Red else MaterialTheme.colorScheme.onSurface 
                                        )
                                    }
                                }
                            }
                            
                            // 3. Description
                            item {
                                Box(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                                     com.coulterpeterson.floatnative.ui.components.HtmlText(
                                        html = contentState.blogPost.text,
                                        modifier = Modifier.fillMaxWidth()
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Sidebar
        androidx.compose.animation.AnimatedVisibility(
            visible = sidebarMode != com.coulterpeterson.floatnative.viewmodels.PlayerSidebarMode.None,
            enter = androidx.compose.animation.slideInHorizontally { it } + androidx.compose.animation.expandHorizontally(),
            exit = androidx.compose.animation.slideOutHorizontally { it } + androidx.compose.animation.shrinkHorizontally()
        ) {
            val contentState = state as? VideoPlayerState.Content
            if (contentState != null) {
                com.coulterpeterson.floatnative.ui.components.tv.TvVideoPlayerSidebar(
                    mode = sidebarMode,
                    descriptionHtml = contentState.blogPost.text ?: "",
                    title = contentState.blogPost.title,
                    publishDate = contentState.blogPost.releaseDate,
                    comments = contentState.comments,
                    onDismiss = { viewModel.closeSidebar() },
                    onSeek = { viewModel.seekTo(it) },
                    videoAttachments = contentState.blogPost.orderedVideoAttachments(
                        contentState.blogPost.attachmentOrder
                    ),
                    selectedVideoId = contentState.selectedVideoId,
                    onSelectVideo = { id -> viewModel.selectVideo(id) },
                )
            }
        }
    }
}
