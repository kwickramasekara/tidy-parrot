import AVFoundation
@preconcurrency import ApplicationServices  // kAXTrustedCheckOptionPrompt is an unannotated global var

@MainActor
public protocol PermissionsProviding {
    /// A denied mic records silence rather than failing, so check this before recording.
    var isMicrophoneAuthorized: Bool { get }
    func requestMicrophoneAccess()
    /// Returns whether the app is trusted, showing the system prompt if it isn't.
    func promptForAccessibility() -> Bool
    /// Calls `granted` once, when the app becomes trusted.
    func waitForAccessibility(_ granted: @escaping @MainActor () -> Void)
}

@MainActor
public struct SystemPermissions: PermissionsProviding {
    public init() {}

    public var isMicrophoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    public func promptForAccessibility() -> Bool {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(prompt)
    }

    public func waitForAccessibility(_ granted: @escaping @MainActor () -> Void) {
        // There's no notification for this grant, so poll.
        Task { @MainActor in
            while !AXIsProcessTrusted() {
                try? await Task.sleep(for: .seconds(1))
            }
            granted()
        }
    }
}
