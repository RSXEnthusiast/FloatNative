//
//  DonateSheet.swift
//  FloatNative
//
//  Modal that shows a QR code linking to the developer's donation page.
//  Linking out via QR (instead of an in-app payment) sidesteps App Store
//  IAP rules for what is a donation to the dev, and works uniformly on
//  iPhone, iPad, and Apple TV (where a tappable URL is awkward).
//
//  Issue: https://github.com/coulterpeterson/FloatNative/issues/34
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct DonateSheet: View {
    @Environment(\.dismiss) private var dismiss

    // Default focus on Close — required for tvOS (no auto-focus), nice on
    // touch for the obvious-dismissal affordance.
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Support FloatNative")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(Color.adaptiveText)

                Text("Scan to donate via Stripe")
                    .font(.subheadline)
                    .foregroundColor(Color.adaptiveSecondaryText)
            }

            if let qr = QRCodeGenerator.image(for: DonationURL.stripe, size: 320) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 320, height: 320)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Donation QR code")
            } else {
                Text("Could not generate QR code.\nVisit \(DonationURL.stripe)")
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color.adaptiveSecondaryText)
                    .padding()
            }

            Text(DonationURL.stripe)
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
            .tint(.floatplaneBlue)
            .focused($closeFocused)
            .padding(.horizontal)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.adaptiveBackground.ignoresSafeArea())
        .onAppear {
            // Land focus on Close so tvOS users (and iPad keyboard users)
            // get a clear default action without hunting.
            closeFocused = true
        }
    }
}

/// Build a QR-code UIImage from a string. Pure Core Image, no deps.
enum QRCodeGenerator {
    static func image(for string: String, size: CGFloat = 256) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel") // high error correction
        guard let output = filter.outputImage else { return nil }

        // Scale up the tiny native QR (≈25×25 px) to the requested size with
        // crisp nearest-neighbor scaling.
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
