package com.coulterpeterson.floatnative.utils

/**
 * Single source of truth for the developer donation link. Change here if
 * the destination ever moves; the Settings donate flow + QR code both read
 * from this constant. Mirrors iOS DonationURL.swift.
 */
object DonationUrl {
    const val STRIPE = "https://donate.stripe.com/fZu6oI3KHfMKbUl9iMaAw0h"
}
