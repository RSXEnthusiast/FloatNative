//
//  DonationURL.swift
//  FloatNative
//
//  Single source of truth for the developer donation link. Change here if
//  the destination ever moves; the Settings donate flow + QR code both read
//  from this constant.
//

import Foundation

enum DonationURL {
    static let stripe = "https://donate.stripe.com/fZu6oI3KHfMKbUl9iMaAw0h"
}
