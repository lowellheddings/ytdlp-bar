import Foundation

package struct DownloadQueue: Equatable, Sendable {
    package private(set) var jobs: [DownloadJob]

    package init(jobs: [DownloadJob] = []) {
        self.jobs = jobs
    }

    @discardableResult
    package mutating func add(
        url: String,
        mode: DownloadMode,
        quality: VideoQuality,
        audioFormat: AudioFormat,
        destination: String,
        now: Date = Date()
    ) -> DownloadJob {
        let sequence = (jobs.map(\.sequence).max() ?? 0) + 1
        let job = DownloadJob(
            id: UUID(),
            sequence: sequence,
            url: url,
            mode: mode,
            quality: quality,
            audioFormat: audioFormat,
            destination: destination,
            status: .queued,
            title: "",
            error: "",
            filePath: nil,
            percent: nil,
            speed: "",
            eta: "",
            added: now,
            finished: nil,
            pid: nil,
            pidStarted: nil
        )
        jobs.append(job)
        return job
    }

    package func job(id: UUID) -> DownloadJob? {
        jobs.first { $0.id == id }
    }

    package func nextQueued() -> DownloadJob? {
        jobs.filter { $0.status == .queued }.min { $0.sequence < $1.sequence }
    }

    package func runningJob() -> DownloadJob? {
        jobs.first { $0.status == .running }
    }

    package var activeJobs: [DownloadJob] {
        jobs.filter { !$0.status.isFinished }.sorted { $0.sequence < $1.sequence }
    }

    package var finishedJobs: [DownloadJob] {
        jobs.filter(\.status.isFinished).sorted { $0.sequence > $1.sequence }
    }

    package var hasFinished: Bool {
        jobs.contains { $0.status.isFinished }
    }

    /// Jobs left `running` belong to a process that died with the app, or to one we still own.
    package mutating func takeInterrupted() -> [InterruptedProcess] {
        var found: [InterruptedProcess] = []
        for index in jobs.indices where jobs[index].status == .running {
            if let pid = jobs[index].pid, let started = jobs[index].pidStarted, pid > 1 {
                found.append(InterruptedProcess(pid: pid, started: started))
            }
            jobs[index].status = .queued
            jobs[index].percent = nil
            jobs[index].speed = ""
            jobs[index].eta = ""
            jobs[index].error = ""
            jobs[index].pid = nil
            jobs[index].pidStarted = nil
        }
        return found
    }

    package mutating func markRunning(id: UUID, pid: Int32, pidStarted: UInt64?) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = .running
        jobs[index].error = ""
        jobs[index].pid = pid
        jobs[index].pidStarted = pidStarted
        jobs[index].finished = nil
    }

    package mutating func noteProgress(id: UUID, percent: Double?, speed: String, eta: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .running else { return }
        jobs[index].percent = percent
        jobs[index].speed = speed
        jobs[index].eta = eta
    }

    /// Returns true when the title changed and should be written to disk.
    @discardableResult
    package mutating func noteTitle(id: UUID, title: String) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != "NA", jobs[index].title != cleaned else { return false }
        jobs[index].title = cleaned
        return true
    }

    package mutating func finish(id: UUID, status: JobStatus, error: String, filePath: String?, now: Date = Date()) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
        jobs[index].error = error
        jobs[index].pid = nil
        jobs[index].pidStarted = nil
        if let filePath, !filePath.isEmpty {
            jobs[index].filePath = filePath
        }
        switch status {
        case .done:
            jobs[index].percent = 100
            jobs[index].speed = ""
            jobs[index].eta = ""
            jobs[index].finished = now
        case .failed, .cancelled:
            jobs[index].speed = ""
            jobs[index].eta = ""
            jobs[index].finished = now
        case .queued:
            jobs[index].percent = nil
            jobs[index].speed = ""
            jobs[index].eta = ""
            jobs[index].finished = nil
        case .running:
            break
        }
    }

    @discardableResult
    package mutating func removeQueued(id: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .queued else {
            return false
        }
        jobs.remove(at: index)
        return true
    }

    package mutating func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
    }
}
