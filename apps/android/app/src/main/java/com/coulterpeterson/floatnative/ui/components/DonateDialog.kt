package com.coulterpeterson.floatnative.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.coulterpeterson.floatnative.utils.DonationUrl
import com.coulterpeterson.floatnative.utils.QrCodeGenerator

/**
 * Modal that shows a QR code linking to the developer's donation page.
 * The Close button grabs focus on open so users with a D-pad / TV remote
 * (and screen-reader users on phones) have a clear default action.
 *
 * Mirrors apps/ios/FloatNative/Views/DonateSheet.swift.
 */
@Composable
fun DonateDialog(onDismiss: () -> Unit) {
    val qrBitmap = remember(DonationUrl.STRIPE) {
        QrCodeGenerator.generate(DonationUrl.STRIPE, sizePx = 512)
    }
    val closeFocus = remember { FocusRequester() }

    LaunchedEffect(Unit) {
        closeFocus.requestFocus()
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Support FloatNative") },
        text = {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = "Scan to donate via Stripe",
                    style = MaterialTheme.typography.bodyMedium,
                )

                if (qrBitmap != null) {
                    Image(
                        bitmap = qrBitmap,
                        contentDescription = "Donation QR code",
                        modifier = Modifier
                            .size(256.dp)
                            .clip(RoundedCornerShape(16.dp))
                            .background(Color.White)
                            .padding(8.dp),
                    )
                } else {
                    Text(
                        text = "Could not generate QR code.\nVisit ${DonationUrl.STRIPE}",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }

                Spacer(Modifier.height(4.dp))
                Text(
                    text = DonationUrl.STRIPE,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = onDismiss,
                modifier = Modifier
                    .focusRequester(closeFocus)
                    .focusable(),
            ) {
                Text("Close")
            }
        },
    )
}
