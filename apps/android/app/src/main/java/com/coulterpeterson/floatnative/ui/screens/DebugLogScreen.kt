package com.coulterpeterson.floatnative.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.coulterpeterson.floatnative.utils.DebugLogManager
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DebugLogScreen(onBack: () -> Unit) {
    val entries by DebugLogManager.entries.collectAsState()
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }

    LaunchedEffect(copied) {
        if (copied) {
            kotlinx.coroutines.delay(1500)
            copied = false
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Debug Log") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(
                        onClick = {
                            copyToClipboard(context, DebugLogManager.exportText())
                            copied = true
                        },
                        enabled = entries.isNotEmpty(),
                    ) {
                        Icon(
                            if (copied) Icons.Default.Check else Icons.Default.ContentCopy,
                            contentDescription = "Copy log",
                        )
                    }
                    IconButton(
                        onClick = { DebugLogManager.clear() },
                        enabled = entries.isNotEmpty(),
                    ) {
                        Icon(Icons.Default.DeleteOutline, contentDescription = "Clear log")
                    }
                },
            )
        },
    ) { padding ->
        if (entries.isEmpty()) {
            Box(
                modifier = Modifier
                    .padding(padding)
                    .fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    "No diagnostic events yet.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .padding(padding)
                    .fillMaxSize(),
                contentPadding = PaddingValues(12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(entries, key = { it.id }) { entry ->
                    EntryCard(entry)
                }
            }
        }
    }
}

@Composable
private fun EntryCard(entry: DebugLogManager.Entry) {
    var expanded by remember { mutableStateOf(false) }
    val canExpand = !entry.detail.isNullOrEmpty()

    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier
            .fillMaxWidth()
            .then(
                if (canExpand) Modifier.clickable { expanded = !expanded }
                else Modifier
            ),
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CategoryBadge(entry.category)
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    formatTime(entry.timestamp.toEpochMilli()),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(modifier = Modifier.weight(1f))
                if (canExpand) {
                    Text(
                        if (expanded) "▲" else "▼",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Spacer(modifier = Modifier.height(6.dp))
            Text(
                entry.message,
                style = MaterialTheme.typography.bodyMedium,
            )
            AnimatedVisibility(visible = expanded && canExpand) {
                Text(
                    entry.detail.orEmpty(),
                    style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
        }
    }
}

@Composable
private fun CategoryBadge(category: DebugLogManager.Category) {
    val color = when (category) {
        DebugLogManager.Category.API -> Color(0xFFE89B33)
        DebugLogManager.Category.DECODE -> MaterialTheme.colorScheme.error
        DebugLogManager.Category.AUTH -> MaterialTheme.colorScheme.primary
        DebugLogManager.Category.OTHER -> MaterialTheme.colorScheme.outline
    }
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(4.dp))
            .background(color.copy(alpha = 0.18f))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    ) {
        Text(
            category.name,
            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
            color = color,
        )
    }
}

private val timeFormatter = SimpleDateFormat("HH:mm:ss", Locale.US)

private fun formatTime(epochMillis: Long): String =
    timeFormatter.format(Date(epochMillis))

private fun copyToClipboard(context: Context, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("FloatNative debug log", text))
}
