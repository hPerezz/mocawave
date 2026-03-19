import SwiftUI

enum ProPaywallSource: String, Identifiable {
    case lufs
    case peakMeter
    case quality
    case coloredWaveform

    var id: String { rawValue }

    var eyebrow: String {
        switch self {
        case .lufs:
            return "Realtime loudness"
        case .peakMeter:
            return "Realtime peak monitoring"
        case .quality:
            return "File quality estimate"
        case .coloredWaveform:
            return "Frequency-colored waveform"
        }
    }

    var title: String {
        switch self {
        case .lufs:
            return "Unlock LUFS monitoring with Pro"
        case .peakMeter:
            return "Unlock dB peak metering with Pro"
        case .quality:
            return "Unlock file quality analysis with Pro"
        case .coloredWaveform:
            return "Unlock RGB Wave with Pro"
        }
    }

    var message: String {
        switch self {
        case .lufs:
            return "See short-term loudness while the track is playing."
        case .peakMeter:
            return "Watch peak amplitude in real time while you audition a file."
        case .quality:
            return "Estimate whether a file lands closer to 128, 192, 256, 320 kbps or lossless."
        case .coloredWaveform:
            return "Render the waveform with spectral color data instead of the standard monochrome view."
        }
    }
}

struct ProPaywallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var proStore: ProEntitlementStore

    let source: ProPaywallSource

    private let includedFeatures: [(icon: String, label: String)] = [
        ("waveform.path.ecg", "Realtime LUFS meter"),
        ("chart.bar.xaxis", "Realtime dB peak meter"),
        ("gauge.with.needle", "Quality estimation"),
        ("paintpalette", "RGB waveform rendering")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            featureList
            pricingCard
            actionArea
            statusMessage
        }
        .padding(24)
        .frame(width: 448)
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            await proStore.prepareIfNeeded()
        }
        .onAppear {
            proStore.clearPurchaseStateIfNeeded()
        }
        .onChange(of: proStore.effectiveProAccess) { hasAccess in
            if hasAccess {
                dismiss()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(source.eyebrow.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.orange.opacity(0.92))

            Text(source.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primary)

            Text(source.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("One-time purchase. No subscription.")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(includedFeatures, id: \.label) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.orange.opacity(0.9))
                        .frame(width: 16)

                    Text(item.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var pricingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let product = proStore.proProduct {
                Text(product.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                Text(product.displayPrice)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)

                if !product.description.isEmpty {
                    Text(product.description)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if proStore.isLoadingProducts {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading App Store pricing…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            } else {
                Text(proStore.productLoadError ?? "Price unavailable right now.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.24), lineWidth: 1)
        )
    }

    private var actionArea: some View {
        HStack(spacing: 10) {
            Button("Restore Purchases") {
                Task {
                    await proStore.restorePurchases()
                }
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)

            Button(primaryButtonTitle) {
                Task {
                    await proStore.purchasePro()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || proStore.proProduct == nil)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch proStore.purchaseState {
        case .idle:
            EmptyView()
        case .purchasing:
            progressStatus("Waiting for App Store confirmation…")
        case .restoring:
            progressStatus("Restoring previous purchases…")
        case .pending:
            messageStatus("The purchase is pending approval.", color: .orange)
        case .purchased:
            messageStatus("Pro unlocked.", color: .green)
        case .restored:
            messageStatus("Previous Pro purchase restored.", color: .green)
        case .cancelled:
            messageStatus("Purchase cancelled.", color: .secondary)
        case .failed(let message):
            messageStatus(message, color: .red)
        }
    }

    private var primaryButtonTitle: String {
        if let product = proStore.proProduct {
            return "Unlock Pro for \(product.displayPrice)"
        }
        return "Unlock Pro"
    }

    private var isBusy: Bool {
        proStore.isLoadingProducts || proStore.purchaseState == .purchasing || proStore.purchaseState == .restoring
    }

    private func progressStatus(_ message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    private func messageStatus(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
