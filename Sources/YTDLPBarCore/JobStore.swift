import Foundation
import os

private let storeLogger = Logger(subsystem: "com.lowellheddings.ytdlp-bar", category: "store")

package struct SavedJobs: Codable, Equatable, Sendable {
    package var version: Int
    package var jobs: [DownloadJob]

    package init(jobs: [DownloadJob]) {
        self.version = 1
        self.jobs = jobs
    }
}

package final class JobStore: @unchecked Sendable {
    package let directory: URL
    private let queue = DispatchQueue(label: "bar.ytdlp.jobs")

    package var file: URL { directory.appendingPathComponent("jobs.json") }

    package init(directory: URL) {
        self.directory = directory
    }

    package static func applicationSupport() -> JobStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return JobStore(directory: base.appendingPathComponent("YTDLPBar", isDirectory: true))
    }

    package func load() -> [DownloadJob] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode(SavedJobs.self, from: data) {
            return saved.jobs
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = root["jobs"] as? [Any] {
            let salvaged: [DownloadJob] = items.compactMap { item in
                guard JSONSerialization.isValidJSONObject(item),
                      let itemData = try? JSONSerialization.data(withJSONObject: item)
                else { return nil }
                return try? decoder.decode(DownloadJob.self, from: itemData)
            }
            if !salvaged.isEmpty || items.isEmpty {
                return salvaged
            }
        }
        quarantine()
        return []
    }

    package func save(_ jobs: [DownloadJob]) {
        let snapshot = jobs
        queue.async { [directory] in
            Self.write(snapshot, directory: directory)
        }
    }

    package func saveSync(_ jobs: [DownloadJob]) {
        let snapshot = jobs
        queue.sync {
            Self.write(snapshot, directory: directory)
        }
    }

    private func quarantine() {
        let bad = file.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: file, to: bad)
        storeLogger.error("Moved an unreadable jobs file aside")
    }

    private static func write(_ jobs: [DownloadJob], directory: URL) {
        let file = directory.appendingPathComponent("jobs.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(SavedJobs(jobs: jobs))
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            storeLogger.error("Could not save jobs: \(error.localizedDescription, privacy: .public)")
        }
    }
}
