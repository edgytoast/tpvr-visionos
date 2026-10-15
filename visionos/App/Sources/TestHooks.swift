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

    /// Seconds since the process started (the kernel's start time), for scripted steps a test
    /// harness outside times its screenshots by.
    static func secondsSinceLaunch() -> TimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_un.__p_starttime
        return Date().timeIntervalSince1970 - (TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1e6)
    }
}
