import Foundation

/// Build-time settings that scripts/build.sh writes into Info.plist.
enum AppConfiguration {
    /// The helper's absolute paths, so moving the project folder needs a rebuild. Nil if the keys are missing.
    static func helper(from info: [String: Any]) -> HelperProcessEngine.Configuration? {
        guard let python = info["TPHelperPython"] as? String, let script = info["TPHelperScript"] as? String else {
            return nil
        }
        return HelperProcessEngine.Configuration(
            python: python, script: script, arguments: info["TPHelperArguments"] as? [String] ?? [])
    }
}
