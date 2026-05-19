package com.coulterpeterson.floatnative.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.coulterpeterson.floatnative.openapi.models.VideoAttachmentModel
import com.coulterpeterson.floatnative.utils.DateUtils

/**
 * Horizontal thumbnail row for posts that bundle multiple video attachments
 * (GH #23). Mirrors the layout of the official Floatplane app: tap a
 * thumbnail to switch the player to that part. The caller is responsible
 * for filtering single-video posts (this composable assumes >1 attachment).
 */
@Composable
fun MultiVideoPicker(
    attachments: List<VideoAttachmentModel>,
    selectedVideoId: String?,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp)
    ) {
        Text(
            text = "${attachments.size} parts",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(bottom = 8.dp)
        )

        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            contentPadding = PaddingValues(end = 16.dp),
        ) {
            items(attachments) { attachment ->
                MultiVideoThumbnail(
                    attachment = attachment,
                    isSelected = attachment.id == selectedVideoId,
                    onClick = { onSelect(attachment.id) }
                )
            }
        }
    }
}

@Composable
private fun MultiVideoThumbnail(
    attachment: VideoAttachmentModel,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val borderColor = if (isSelected)
        MaterialTheme.colorScheme.primary
    else
        Color.Transparent

    Column(
        modifier = Modifier
            .width(200.dp)
            .clickable(onClick = onClick)
    ) {
        Box {
            AsyncImage(
                // ImageModel.path is a java.net.URI; Coil treats only the
                // String form as a remote URL — passing the URI object
                // silently fails the load (the picker tile showed up blank).
                model = attachment.thumbnail.path.toString(),
                contentDescription = attachment.title,
                modifier = Modifier
                    .size(width = 200.dp, height = 112.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .border(3.dp, borderColor, RoundedCornerShape(8.dp)),
                contentScale = ContentScale.Crop,
            )
            Surface(
                color = Color.Black.copy(alpha = 0.8f),
                shape = RoundedCornerShape(4.dp),
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(6.dp),
            ) {
                Text(
                    text = DateUtils.formatDuration(attachment.duration.toLong()),
                    style = MaterialTheme.typography.labelSmall,
                    color = Color.White,
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 3.dp),
                )
            }
        }
        Text(
            text = attachment.title,
            style = MaterialTheme.typography.bodySmall,
            color = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
            maxLines = 2,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}
