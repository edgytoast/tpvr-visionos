import Foundation

/// The environment variables that drive the launcher's headless Simulator runs (visionos/README.md,
/// "Testing in the Simulator"). They exist only in Simulator builds: an app installed on a headset
/// ignores them. Set but empty counts as not set, so a test script can pass every hook and leave the
/// ones it doesn't need blank. (The game's older hooks, TPVR_AUTO_PLAY and the TPVR_TEST_WINDOW_*
/// ones, read the environment directly.)
enum TestHooks {
    static func value(_ name: String) -> String? {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
        #else
        nil
        #endif
    }
}
