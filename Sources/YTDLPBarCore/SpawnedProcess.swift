import Darwin
import Foundation

package enum SpawnError: Error, CustomStringConvertible, Equatable {
    case pipe
    case fileAction(Int32)
    case spawn(Int32)

    package var description: String {
        switch self {
        case .pipe:
            "Could not open a pipe."
        case .fileAction(let code), .spawn(let code):
            String(cString: strerror(code))
        }
    }
}

/// yt-dlp and the ffmpeg it launches share a process group, so cancel reaches both.
package final class SpawnedProcess: @unchecked Sendable {
    package let pid: pid_t
    private let lock = NSLock()
    private var reaped = false
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private let onLine: @Sendable (String) -> Void
    private let readers = DispatchGroup()

    private init(pid: pid_t, stdoutFD: Int32, stderrFD: Int32, onLine: @escaping @Sendable (String) -> Void) {
        self.pid = pid
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
        self.onLine = onLine
    }

    package static func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: String,
        onLine: @escaping @Sendable (String) -> Void
    ) throws -> SpawnedProcess {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw SpawnError.pipe }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0])
            close(outPipe[1])
            throw SpawnError.pipe
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(outPipe[0]); close(outPipe[1]); close(errPipe[0]); close(errPipe[1])
            throw SpawnError.fileAction(errno)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else {
            close(outPipe[0]); close(outPipe[1]); close(errPipe[0]); close(errPipe[1])
            throw SpawnError.fileAction(errno)
        }
        defer { posix_spawnattr_destroy(&attr) }

        // pgid 0 makes the child the leader of a new group. kill(-pid) then stops ffmpeg too.
        if posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP)) != 0
            || posix_spawnattr_setpgroup(&attr, 0) != 0 {
            close(outPipe[0]); close(outPipe[1]); close(errPipe[0]); close(errPipe[1])
            throw SpawnError.fileAction(errno)
        }

        let devNull = open("/dev/null", O_RDONLY)
        if devNull >= 0 {
            posix_spawn_file_actions_adddup2(&actions, devNull, STDIN_FILENO)
            posix_spawn_file_actions_addclose(&actions, devNull)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, outPipe[0])
        posix_spawn_file_actions_addclose(&actions, outPipe[1])
        posix_spawn_file_actions_addclose(&actions, errPipe[0])
        posix_spawn_file_actions_addclose(&actions, errPipe[1])
        if !directory.isEmpty {
            let chdirResult = directory.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
            if chdirResult != 0 {
                if devNull >= 0 { close(devNull) }
                close(outPipe[0]); close(outPipe[1]); close(errPipe[0]); close(errPipe[1])
                throw SpawnError.fileAction(chdirResult)
            }
        }

        var pid: pid_t = 0
        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }.sorted()
        let rc: Int32 = executable.withCString { path in
            argv.withCStrings { argvPointer in
                envp.withCStrings { envPointer in
                    posix_spawn(&pid, path, &actions, &attr, argvPointer, envPointer)
                }
            }
        }

        if devNull >= 0 { close(devNull) }
        close(outPipe[1])
        close(errPipe[1])

        guard rc == 0, pid > 1 else {
            close(outPipe[0])
            close(errPipe[0])
            throw SpawnError.spawn(rc == 0 ? ECHILD : rc)
        }

        _ = fcntl(outPipe[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(errPipe[0], F_SETFD, FD_CLOEXEC)

        let process = SpawnedProcess(pid: pid, stdoutFD: outPipe[0], stderrFD: errPipe[0], onLine: onLine)
        process.startReaders()
        return process
    }

    package func cancel() {
        signal(SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let done = self.reaped
            self.lock.unlock()
            if !done {
                self.signal(SIGKILL)
            }
        }
    }

    package func killNow() {
        signal(SIGKILL)
    }

    /// The group covers ffmpeg. The pid covers a child that never became a group leader.
    private func signal(_ sig: Int32) {
        guard pid > 1 else { return }
        kill(-pid, sig)
        kill(pid, sig)
    }

    package func waitForExit() -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { break }
            if result < 0 && errno != EINTR { break }
        }
        lock.lock()
        reaped = true
        lock.unlock()
        readers.wait()
        return Self.exitCode(status)
    }

    private func startReaders() {
        for fd in [stdoutFD, stderrFD] {
            readers.enter()
            let onLine = self.onLine
            let readers = self.readers
            Thread.detachNewThread {
                Self.readLines(fd: fd, onLine: onLine)
                readers.leave()
            }
        }
    }

    private static func readLines(fd: Int32, onLine: @Sendable (String) -> Void) {
        var storage = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(fd, base, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break }
            storage.append(chunk, count: count)
            while let newline = storage.firstIndex(of: 0x0A) {
                let piece = storage.subdata(in: 0..<newline)
                storage.removeSubrange(0...newline)
                emit(piece, onLine: onLine)
            }
        }
        if !storage.isEmpty {
            emit(storage, onLine: onLine)
        }
        close(fd)
    }

    private static func emit(_ data: Data, onLine: (String) -> Void) {
        var data = data
        if data.last == 0x0D { data.removeLast() }
        guard !data.isEmpty else { return }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        if !text.isEmpty { onLine(text) }
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        if status & 0x7F == 0 {
            return (status >> 8) & 0xFF
        }
        let signal = status & 0x7F
        if signal != 0x7F { return 128 + signal }
        return status
    }

    deinit {
        lock.lock()
        let alreadyReaped = reaped
        lock.unlock()
        if !alreadyReaped {
            signal(SIGKILL)
        }
    }
}

package final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    package init() {}

    package func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    package func drain() -> [String] {
        lock.lock()
        let copy = lines
        lines.removeAll(keepingCapacity: true)
        lock.unlock()
        return copy
    }
}

extension Array where Element == String {
    fileprivate func withCStrings<R>(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers { free(pointer) }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}
