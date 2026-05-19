package com.coulterpeterson.floatnative.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Android
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.coulterpeterson.floatnative.utils.WhatsNewRepository

/**
 * "What's New" release-notes dialog. Triggered on launch after an app
 * update (auto), or from Settings (manual). See WhatsNewRepository.
 */
@Composable
fun WhatsNewDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val content = remember { WhatsNewRepository.content(context) } ?: return
    val closeFocus = remember { FocusRequester() }

    LaunchedEffect(Unit) { closeFocus.requestFocus() }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(content.title) },
        text = {
            LazyColumn(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                items(content.items) { item ->
                    WhatsNewRow(item)
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = onDismiss,
                modifier = Modifier.focusRequester(closeFocus),
            ) {
                Text("Got it")
            }
        },
    )
}

@Composable
private fun WhatsNewRow(item: WhatsNewRepository.Item) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            imageVector = iconFor(item.icon),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(MaterialTheme.colorScheme.primaryContainer)
                .padding(8.dp),
        )
        Spacer(Modifier.size(12.dp))
        Column(modifier = Modifier.fillMaxWidth()) {
            Text(
                text = item.title,
                style = MaterialTheme.typography.titleSmall,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text = item.body,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

private fun iconFor(name: String): ImageVector = when (name.lowercase()) {
    "favorite", "heart" -> Icons.Filled.Favorite
    "speed", "speedometer" -> Icons.Filled.Speed
    "lightbulb", "bolt" -> Icons.Filled.Lightbulb
    "tv" -> Icons.Filled.Tv
    "android" -> Icons.Filled.Android
    "star", "sparkles" -> Icons.Filled.Star
    else -> Icons.Filled.Info
}
