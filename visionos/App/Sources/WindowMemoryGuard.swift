import Foundation
import Metal
import QuartzCore
import os

/// Window mode's memory guard and log. On the headset, loading a save in the window once made the
/// app's footprint climb by about 800 MB a second until visionOS itself froze and had to be reset:
/// the Simulator never shows it, since there the GPU's memory isn't the app's. So the window
/// checks the app's footprint a few times a second, writes what it's made of to
/// Library/Logs/window-diagnostics.log (read off the headset with devicectl's appDataContainer
/// domain) and, if it runs away, has the scene mirror go (the window shows the game's flat picture)
/// and then, if that isn't enough, the game quit, rather than take the headset down.
@MainActor
final class WindowMemoryGuard {
    enum Action { case none, dropMirror, quit, forceExit }

    /// The app's memory, from TASK_VM_INFO: the footprint visionOS holds it to, and what it's made
    /// of (heap, compressed, the GPU's and media's ledgers), to tell a GPU leak from a heap one.
    struct Memory {
        var footprint: UInt64 = 0, peak: UInt64 = 0, heap: UInt64 = 0, compressed: UInt64 = 0
        var graphics: UInt64 = 0, media: UInt64 = 0
    }

    private let device: MTLDevice
    private var lastCheck = 0.0
    private var lastLog = 0.0
    private var samples: [(time: Double, footprint: UInt64)] = []
    private var droppedAt: Double?
    private var quitAt: Double?
    private var file: FileHandle?
    private let start = CACurrentMediaTime()
    nonisolated private static let log = Logger(subsystem: "dev.tpvr.vision", category: "window-memory")

    // Normal play in the window sits around 1 to 1.5 GB on the headset. Test runs:
    // TPVR_TEST_WINDOW_MEMORY_MB=<n> drops the mirror past n MB instead (and quits 1 GB later),
    // to try the guard where memory doesn't run away (the Simulator).
    private static let testCeiling = ProcessInfo.processInfo.environment["TPVR_TEST_WINDOW_MEMORY_MB"]
        .flatMap(UInt64.init).map { $0 << 20 }
    private static let runawayGrowth: UInt64 = 1536 << 20       // in the last 3 seconds
    private static let stillGrowing: UInt64 = 512 << 20         // in the last second, after the drop
    private static let mirrorCeiling: UInt64 = testCeiling ?? 5 << 30          // the mirror goes past this
    private static let quitCeiling: UInt64 = mirrorCeiling + (1 << 30)        // and the game past this
    private static let minimumAvailable: UInt64 = 1 << 30       // left before the app's limit

    init(device: MTLDevice) {
        self.device = device
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let url = logs.appendingPathComponent("window-diagnostics.log")
        // The last run's log is kept, in case the window opens again before it's read.
        let previous = logs.appendingPathComponent("window-diagnostics.previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
    }

    /// Called every window update; checks four times a second. `hasMirror`: the mirror is still
    /// there to drop. `mirror` describes what it holds, `extra` the window's own state, for the log.
    func check(hasMirror: Bool, mirror: () -> String, extra: () -> String) -> Action {
        let now = CACurrentMediaTime()
        guard now - lastCheck >= 0.25 else { return .none }
        lastCheck = now
        let memory = Self.memory()
        let available = UInt64(os_proc_available_memory())
        samples.append((now, memory.footprint))
        samples.removeAll { now - $0.time > 3.5 }  // a sample at or before 3 s ago stays the baseline
        let growth = Self.growth(of: samples, since: now - 3, to: memory.footprint)
        let lastSecond = Self.growth(of: samples, since: now - 1, to: memory.footprint)
        // With the increased memory limit, this stays large long after the headset suffers.
        let starved = available > 0 && available < Self.minimumAvailable
        let runaway = growth > Self.runawayGrowth || memory.footprint > Self.mirrorCeiling || starved

        var action = Action.none
        var note = ""
        if let quitAt {
            // Asked again until the game has gone; if it hasn't in two seconds, the app goes.
            action = now - quitAt > 2 ? .forceExit : .quit
            if action == .forceExit { note = "  >>> the game didn't quit in time: the app exits" }
        } else if runaway && droppedAt == nil && hasMirror {
            droppedAt = now
            action = .dropMirror
            note = "  >>> memory running away: the mirror goes, the window shows the game's relief"
        } else if runaway && (droppedAt.map { now - $0 >= 1 && lastSecond > Self.stillGrowing } ?? !hasMirror)
                    || (droppedAt != nil || !hasMirror) && (memory.footprint > Self.quitCeiling || starved) {
            quitAt = now
            action = .quit
            note = hasMirror || droppedAt != nil ? "  >>> still running away without the mirror: the game quits"
                                                 : "  >>> memory running away, no mirror to drop: the game quits"
        }
        if now - lastLog >= 2 || !note.isEmpty {
            lastLog = now
            let line = String(format: "%7.1f s  footprint %5llu MB (+%llu in 3 s, +%llu in 1 s; peak %llu): heap %llu, "
                              + "compressed %llu, graphics %llu, media %llu; available %llu, Metal %llu | ",
                              now - start, memory.footprint >> 20, growth >> 20, lastSecond >> 20, memory.peak >> 20,
                              memory.heap >> 20, memory.compressed >> 20, memory.graphics >> 20, memory.media >> 20,
                              available >> 20, UInt64(device.currentAllocatedSize) >> 20)
                + "mirror: \(mirror()) | \(extra())" + note
            write(line, flush: !note.isEmpty)
        }
        return action
    }

    /// Growth since `since`, from the newest sample at or before it (checks come at least 0.25 s
    /// apart, so the first one after it would cover less than the span).
    private static func growth(of samples: [(time: Double, footprint: UInt64)], since: Double, to now: UInt64) -> UInt64 {
        guard let base = samples.last(where: { $0.time <= since }) ?? samples.first else { return 0 }
        return now > base.footprint ? now - base.footprint : 0
    }

    private func write(_ line: String, flush: Bool) {
        Self.log.notice("[TPVR] window memory: \(line, privacy: .public)")
        // A full disk mustn't take the app down: the write that fails stops the file.
        do {
            try file?.write(contentsOf: Data((line + "\n").utf8))
            if flush { try file?.synchronize() }
        } catch {
            file = nil
        }
    }

    /// The app's memory now (TASK_VM_INFO's ledgers).
    nonisolated static func memory() -> Memory {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Memory() }
        let ledger = { (value: Int64) in UInt64(max(0, value)) }
        return Memory(footprint: info.phys_footprint, peak: ledger(info.ledger_phys_footprint_peak), heap: info.internal,
                      compressed: info.compressed, graphics: ledger(info.ledger_tag_graphics_footprint),
                      media: ledger(info.ledger_tag_media_footprint))
    }
}
