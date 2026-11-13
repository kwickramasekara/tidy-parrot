import AppKit
import Testing

@testable import TidyParrotCore

/// Uses a private pasteboard and a fake ⌘V, so tests never touch the user's clipboard or focused app.
@MainActor
struct PasteboardTextInserterTests {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("TidyParrotTests-\(UUID().uuidString)"))
    let restoreDelay = Duration.milliseconds(30)

    func makeInserter(onPaste: @escaping @MainActor () -> Void = {}) -> PasteboardTextInserter {
        PasteboardTextInserter(pasteboard: pasteboard, restoreDelay: restoreDelay, paste: onPaste)
    }

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func waitForClipboard(_ expected: String?) async throws {
        try await waitUntil { pasteboard.string(forType: .string) == expected }
    }

    /// For checks that something is left alone: there's no change to wait for, so give the restore time to run.
    func afterRestoreWindow() async throws {
        try await Task.sleep(for: restoreDelay * 5)
    }

    @Test func pastesTextThenRestoresClipboard() async throws {
        copy("user's clipboard")
        var pastedText: String?
        let inserter = makeInserter { pastedText = pasteboard.string(forType: .string) }

        inserter.insert("dictated")
        #expect(pastedText == "dictated")
        try await waitForClipboard("user's clipboard")
    }

    @Test func marksDictationTransientForClipboardManagers() {
        let inserter = makeInserter()
        inserter.insert("dictated")
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
    }

    @Test func backToBackDictationsStillRestoreTheUsersClipboard() async throws {
        copy("user's clipboard")
        let inserter = makeInserter()
        inserter.insert("first")
        inserter.insert("second")
        try await waitForClipboard("user's clipboard")
    }

    @Test func somethingCopiedMeanwhileIsLeftAlone() async throws {
        copy("user's clipboard")
        let inserter = makeInserter()
        inserter.insert("dictated")
        copy("copied during the delay")
        try await afterRestoreWindow()
        #expect(pasteboard.string(forType: .string) == "copied during the delay")
    }

    @Test func copyBetweenDictationsBecomesTheContentToRestore() async throws {
        copy("old clipboard")
        let inserter = makeInserter()
        inserter.insert("first")
        copy("new clipboard")
        inserter.insert("second")
        try await waitForClipboard("new clipboard")
    }

    @Test func emptyClipboardIsRestoredEmpty() async throws {
        pasteboard.clearContents()
        let inserter = makeInserter()
        inserter.insert("dictated")
        try await waitForClipboard(nil)
    }
}
