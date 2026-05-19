//
//  FeedbackSheet.swift
//  FloatNative
//
//  Modal that shows a QR code linking to the developer's Discord server.
//  Mirrors DonateSheet — used on tvOS where tapping a URL isn't a thing.
//

import SwiftUI

enum FeedbackURL {
    static let discord = "https://discord.gg/VvgCsKBwpP"
}

struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Send Feedback via Discord")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(Color.adaptiveText)

                Text("Scan to join the Discord and share feedback")
                    .font(.subheadline)
                    .foregroundColor(Color.adaptiveSecondaryText)
            }

            if let qr = QRCodeGenerator.image(for: FeedbackURL.discord, size: 320) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 320, height: 320)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Discord invite QR code")
            } else {
                Text("Could not generate QR code.\nVisit \(FeedbackURL.discord)")
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color.adaptiveSecondaryText)
                    .padding()
            }

            Text(FeedbackURL.discord)
                .font(.footnote)
                .foregroundColor(Color.adaptiveSecondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                dismiss()
            } label: {
                Text("Close")
                    .font(.body)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .focused($closeFocused)
            .padding(.horizontal)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.adaptiveBackground.ignoresSafeArea())
        .onAppear {
            closeFocused = true
        }
    }
}
