// DEBUG: Temporary file for issue #882 safe area debugging.
// Remove this entire file once the bug is resolved.

import Foundation
import SwiftUI
import UIKit

// MARK: - Log buffer

final class DebugSafeAreaLogger {
    static let shared = DebugSafeAreaLogger()

    private var entries: [(Date, String)] = []
    private let lock = NSLock()
    private let maxEntries = 2000

    private init() {}

    func log(_ tag: String, _ message: String) {
        let timestamp = Date()
        let line = "\(tag) \(message)"
        print(line) // still print to Xcode console when connected

        lock.lock()
        entries.append((timestamp, line))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()
    }

    func export() -> String {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        var output = "=== #882 Safe Area Debug Log ===\n"
        output += "Exported: \(Date())\n"
        output += "Device: \(UIDevice.current.model) (\(UIDevice.current.systemVersion))\n"
        output += "Screen: \(UIScreen.main.bounds.width)x\(UIScreen.main.bounds.height)\n"
        output += "Entries: \(snapshot.count)\n"
        output += "================================\n\n"

        for (date, line) in snapshot {
            output += "[\(formatter.string(from: date))] \(line)\n"
        }

        return output
    }

    func saveToFile() -> URL? {
        let content = export()
        let fileName = "trio_882_debug_\(Int(Date().timeIntervalSince1970)).log"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("🔴 [#882] Failed to write log file: \(error)")
            return nil
        }
    }
}

// Convenience for logging
func debugLog882(_ tag: String, _ message: String) {
    DebugSafeAreaLogger.shared.log(tag, message)
}

// MARK: - Shake detection

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            Foundation.NotificationCenter.default.post(
                name: .debug882DeviceShaken,
                object: nil as Any?
            )
        }
    }
}

extension Notification.Name {
    static let debug882DeviceShaken = Notification.Name("debug882DeviceShaken")
}

// MARK: - Share sheet modifier

struct DebugShakeExportModifier: ViewModifier {
    @State private var showShare = false
    @State private var logFileURL: URL?
    @State private var showSaved = false

    func body(content: Content) -> some View {
        content
            .onReceive(
                Foundation.NotificationCenter.default.publisher(for: .debug882DeviceShaken)
            ) { _ in
                if let url = DebugSafeAreaLogger.shared.saveToFile() {
                    logFileURL = url
                    showShare = true
                    debugLog882("📱", "Shake detected — log saved to \(url.lastPathComponent)")
                }
            }
            .sheet(isPresented: $showShare) {
                if let url = logFileURL {
                    ShareSheet(activityItems: [url])
                        .presentationDetents([.medium])
                }
            }
            .overlay(alignment: .top) {
                if showSaved {
                    Text("Debug log saved!")
                        .font(.caption.bold())
                        .padding(8)
                        .background(.green.opacity(0.9))
                        .foregroundStyle(.white)
                        .cornerRadius(8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 100)
                }
            }
    }
}

// UIActivityViewController wrapper for SwiftUI
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension View {
    func debugShakeExport() -> some View {
        modifier(DebugShakeExportModifier())
    }
}
