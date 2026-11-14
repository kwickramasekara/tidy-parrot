import AppKit
import ApplicationServices

@MainActor
protocol FocusedInputChecking {
    /// False only when the focused element certainly can't take text. When Accessibility can't tell, true.
    func hasFocusedTextInput() -> Bool
}

/// Asks Accessibility what has keyboard focus. Fails open: Electron apps (Slack, VS Code) often report no focused
/// element until their accessibility tree is switched on, and web pages briefly report a group or window while you
/// type, so silence or a container is no proof there's nowhere to paste. Forcing Electron's tree on
/// (`AXManualAccessibility`) is avoided: it costs CPU and takes about 2 s to apply.
@MainActor
struct AccessibilityFocusedInput: FocusedInputChecking {
    /// Roles that never take typed text. Containers (AXGroup, AXWebArea, AXScrollArea, AXTable, AXWindow) are left
    /// out on purpose: web pages, Electron, spreadsheets and Alacritty report them while you're editing.
    nonisolated static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
        "AXDisclosureTriangle", "AXSlider", "AXIncrementor", "AXScrollBar", "AXImage", "AXList", "AXOutline",
        "AXBrowser",
    ]

    /// AX calls are synchronous IPC on the main actor, and the default timeout is seconds long, so a hung app would
    /// freeze the hotkey. Set on the system-wide element, it applies to every AX call this process makes.
    private static let messagingTimeout: Float = 0.1

    nonisolated static func mayTakeText(role: String?) -> Bool {
        guard let role else { return true }
        return !nonTextRoles.contains(role)
    }

    func hasFocusedTextInput() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)
        let focused = Self.copyElement(systemWide, kAXFocusedUIElementAttribute)
        let role = focused.flatMap { Self.copyString($0, kAXRoleAttribute) }
        let accepted = Self.mayTakeText(role: role)
        // Roles and app IDs only, never content: enough to tune `nonTextRoles` from real use.
        if let role, !accepted {
            Log.write("no text input: focused \(role) in \(Self.bundleID(of: focused))")
        } else if role == nil {
            Log.write("focus unknown in \(Self.bundleID(of: focused)); allowed")
        }
        return accepted
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // CF types can't be checked with `as?`; the type ID check above makes this cast safe.
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bundleID(of element: AXUIElement?) -> String {
        var pid: pid_t = 0
        let app =
            if let element, AXUIElementGetPid(element, &pid) == .success {
                NSRunningApplication(processIdentifier: pid)
            } else {
                NSWorkspace.shared.frontmostApplication
            }
        return app?.bundleIdentifier ?? "unknown app"
    }
}
