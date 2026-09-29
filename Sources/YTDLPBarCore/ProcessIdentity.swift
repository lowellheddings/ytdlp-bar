import Darwin
import Foundation

package enum ProcessIdentity {
    /// Start time pins a pid so a recycled number is not signalled.
    package static func startSeconds(pid: pid_t) -> UInt64? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let written = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard written == size, info.pbi_pid == UInt32(pid) else { return nil }
        return info.pbi_start_tvsec
    }

    package static func matches(pid: Int32, started: UInt64) -> Bool {
        guard let actual = startSeconds(pid: pid) else { return false }
        return actual == started
    }

    package static func terminateOwned(pid: Int32, started: UInt64) {
        guard pid > 1, matches(pid: pid, started: started) else { return }
        kill(-pid, SIGTERM)
        usleep(200_000)
        guard matches(pid: pid, started: started) else { return }
        kill(-pid, SIGKILL)
    }
}
