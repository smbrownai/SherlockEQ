import SwiftUI

/// Credits for the science, software, and prior art SherlockEQ stands on.
/// Surfaced from Settings as a sheet.
struct AcknowledgmentsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section(
                        title: "Hearing-safety math",
                        body: "Listening-dose calculations follow NIOSH's recommended exposure limit (REL): 85 dBA over 8 hours with a 3 dB exchange rate. Source: U.S. National Institute for Occupational Safety and Health, Criteria for a Recommended Standard: Occupational Noise Exposure (DHHS Publication No. 98-126, 1998)."
                    )
                    section(
                        title: "Biquad filter coefficients",
                        body: "Per-band response uses the Audio EQ Cookbook formulas by Robert Bristow-Johnson — the de facto reference for parametric, shelving, notch, band-pass, low-pass, and high-pass biquads in audio software."
                    )
                    section(
                        title: "Headphone correction",
                        body: "AutoEQ file format compatibility — including PK / LSC / HSC filter types and preamp adjustments — follows the AutoEq project by Jaakko Pasanen. Many real-world correction curves come from oratory1990 (Reddit r/oratory1990) and Crinacle's measurement database."
                    )
                    section(
                        title: "Apple frameworks",
                        body: "Built on AVFoundation, Core Audio Taps (introduced in macOS 14.4), AudioUnit's AUPeakLimiter, Accelerate's vDSP DFT, SwiftUI, ServiceManagement, and Combine."
                    )
                    section(
                        title: "Author",
                        body: "SherlockEQ is © Shawn Brown."
                    )
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 460, idealHeight: 540)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "info.circle")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Acknowledgments").font(.title3.weight(.semibold))
                Text("Science, software, and prior art")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(body)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
