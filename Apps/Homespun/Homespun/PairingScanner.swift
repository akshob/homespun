// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI
import VisionKit

/// Scans the QR code that `homespun-server pair` prints. Not available on the simulator.
struct PairingScanner: UIViewControllerRepresentable {
    let found: (PairingLink) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

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
