// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import HomespunCore
import SwiftUI
import VisionKit

/// Scans the QR code that `homespun-server pair` prints. Not available on the simulator.
struct PairingScanner: UIViewControllerRepresentable {
    let found: (PairingLink) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }
    /// This device can scan at all (not the simulator), whether or not the camera is allowed yet.
    static var isSupported: Bool { DataScannerViewController.isSupported }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (PairingLink) -> Void
        private var done = false

        init(found: @escaping (PairingLink) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in items {
                guard !done, let text = barcode.payloadStringValue, let link = PairingLink(text: text) else { continue }
                done = true
                scanner.stopScanning()
                found(link)
            }
        }
    }
}

/// Scan QR code (DESIGN 01·6.3): the viewfinder with one line of help, or how to allow the camera.
struct ScanPage: View {
    var permissionsAllowed = true
    let found: (PairingLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            Group {
                if !permissionsAllowed {
                    ContentUnavailableView("The demo doesn't use the camera", systemImage: "qrcode.viewfinder",
                                           description: Text("Use the demo's pairing code instead."))
                } else if camera == .denied || camera == .restricted {
                    ContentUnavailableView {
                        Label("Homespun can't use the camera", systemImage: "camera")
                    } description: {
                        Text("Allow the camera in Settings › Apps › Homespun to scan the QR code your server shows. "
                             + "Or paste the pairing link, or enter the address and code.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .primaryAction()
                    }
                } else if PairingScanner.isAvailable {
                    PairingScanner(found: found)
                        .ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            Text("Point at the QR code your server shows")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .glassEffect()
                                .padding(.bottom, 32)
                        }
                } else {
                    ContentUnavailableView("Scanning isn't available here", systemImage: "qrcode.viewfinder",
                                           description: Text("Paste the pairing link, or enter the address and code."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.accessibilityIdentifier("scan.close")
                }
            }
        }
        .task {
            if permissionsAllowed, camera == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                camera = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }
}
