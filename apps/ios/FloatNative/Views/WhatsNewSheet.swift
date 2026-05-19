//
//  WhatsNewSheet.swift
//  FloatNative
//
//  Modal that highlights what changed in this release. Shown automatically
//  once per release (or on demand from Settings). See WhatsNewService and
//  issue #42.
//

import SwiftUI

struct WhatsNewSheet: View {
    @ObservedObject private var service = WhatsNewService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let content = service.content {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        Text(content.title)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(Color.adaptiveText)
                            .multilineTextAlignment(.center)
                            .padding(.top, 32)
                            .padding(.horizontal)

                        VStack(spacing: 20) {
                            ForEach(content.items) { item in
                                WhatsNewRow(item: item)
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                Button {
                    service.dismiss()
                    dismiss()
                } label: {
                    Text("Got it")
                        .font(.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.floatplaneBlue)
                .padding(.horizontal)
                .padding(.bottom, 24)
                .padding(.top, 12)
            }
            .background(Color.adaptiveBackground.ignoresSafeArea())
        } else {
            // Defensive — shouldn't be reachable since we only present when
            // content is non-nil, but render *something* if state drifts.
            VStack {
                Text("Nothing new yet.")
                Button("Close") { dismiss() }
            }
            .padding()
        }
    }
}

private struct WhatsNewRow: View {
    let item: WhatsNewContent.Item

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: item.icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.floatplaneBlue)
                .frame(width: 36, height: 36)
                .padding(8)
                .background(Color.floatplaneBlue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(Color.adaptiveText)

                Text(item.body)
                    .font(.subheadline)
                    .foregroundColor(Color.adaptiveSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}
