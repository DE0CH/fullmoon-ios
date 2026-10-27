//
//  ModelDownloader.swift
//  fullmoon
//
//  Downloads the model in the background (a background URLSession keeps going while the app is suspended or
//  closed) as byte ranges written straight into the final files, so it can be paused, survives the app being
//  killed, and needs no second copy on disk. Each range is checked against the server's Content-Range; the
//  finished files are checked against Hugging Face's SHA-256.
//

import CryptoKit
import Foundation
import os
import UIKit
import UserNotifications

private let log = Logger(subsystem: "dev.de0ch.fullmoon", category: "download")

/// A byte range of one model file; its key doubles as the URLSession task description, so tasks still running
/// after a relaunch are recognised.
struct Chunk: Hashable, Sendable {
    let file: String
    let offset: Int64
    let length: Int64

    var key: String { "\(file)|\(offset)|\(length)" }

    init(file: String, offset: Int64, length: Int64) {
        self.file = file
        self.offset = offset
        self.length = length
    }

    init?(key: String) {
        let parts = key.split(separator: "|")
        guard parts.count == 3, let offset = Int64(parts[1]), let length = Int64(parts[2]) else { return nil }
        self.init(file: String(parts[0]), offset: offset, length: length)
    }
}

@Observable
@MainActor
final class ModelDownloader: NSObject {
    enum Phase: Equatable {
        case notStarted, downloading, paused, verifying, ready
        case failed(String)
    }

    static let shared = ModelDownloader()

    let spec = ModelSpec.current
    private(set) var phase: Phase = .notStarted
    /// bytes finished (whole chunks) plus bytes of chunks in flight
    private(set) var receivedBytes: Int64 = 0
    private(set) var bytesPerSecond: Double = 0
    /// shown under the progress bar while a range is being retried (e.g. no network)
    private(set) var note: String?

    var totalBytes: Int64 { spec.totalBytes }
    var fraction: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }
    var isReady: Bool { phase == .ready }

    /// where the model lives; the loader reads it from here
    nonisolated static let modelDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "model/\(ModelSpec.current.repo.replacingOccurrences(of: "/", with: "--"))")
    }()

    nonisolated private static let doneFile = modelDirectory.appending(path: ".done-chunks")
    nonisolated private static let readyFile = modelDirectory.appending(path: ".ready")
    nonisolated private static let sessionID = "dev.de0ch.fullmoon.model-download"
    private static let pausedKey = "modelDownloadPaused"
    private static let startedKey = "modelDownloadStarted"

    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var done: Set<String> = []
    @ObservationIgnored private var inFlight: [String: Int64] = [:]
    @ObservationIgnored private var retryCounts: [String: Int] = [:]
    @ObservationIgnored private var speedSample: (time: Date, bytes: Int64)?
    @ObservationIgnored private var speedTask: Task<Void, Never>?

    @ObservationIgnored private let chunks: [Chunk] = ModelSpec.current.files.flatMap { file in
        let size = ModelSpec.current.chunkSize
        return stride(from: Int64(0), to: file.size, by: Int(size)).map {
            Chunk(file: file.name, offset: $0, length: min(size, file.size - $0))
        }
    }

    override private init() {
        super.init()
        if ModelSpec.isUITest, ProcessInfo.processInfo.arguments.contains("-reset") {
            try? FileManager.default.removeItem(at: Self.modelDirectory)
            UserDefaults.standard.removeObject(forKey: Self.pausedKey)
            UserDefaults.standard.removeObject(forKey: Self.startedKey)
        }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // the UI tests fetch their small ranges one at a time, slowly enough to pause mid-download
        config.httpMaximumConnectionsPerHost = ModelSpec.isUITest ? 1 : 4
        config.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        Self.removeOtherModels()
        // ranges still queued for a model the app no longer uses would be written into this model's files
        let prefix = ModelSpec.current.url(for: ModelSpec.current.files[0]).deletingLastPathComponent().absoluteString
        session.getAllTasks { tasks in
            tasks.filter { !($0.originalRequest?.url?.absoluteString.hasPrefix(prefix) ?? false) }.forEach { $0.cancel() }
        }

        if FileManager.default.fileExists(atPath: Self.readyFile.path) {
            phase = .ready
            receivedBytes = totalBytes
            return
        }
        done = Self.loadDone()
        receivedBytes = doneBytes
        if UserDefaults.standard.bool(forKey: Self.startedKey) {
            if UserDefaults.standard.bool(forKey: Self.pausedKey) {
                phase = .paused
            } else {
                start()
            }
        }
    }

    /// frees the space of a model an earlier version of the app used (each model has its own directory)
    nonisolated private static func removeOtherModels() {
        let parent = modelDirectory.deletingLastPathComponent()
        let others = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        for dir in others where dir.lastPathComponent != modelDirectory.lastPathComponent {
            try? FileManager.default.removeItem(at: dir)
            log.notice("removed old model \(dir.lastPathComponent)")
        }
    }

    private var doneBytes: Int64 {
        chunks.filter { done.contains($0.key) }.reduce(0) { $0 + $1.length }
    }

    // MARK: - controls

    func start() {
        guard phase != .ready, phase != .verifying else { return }
        let remaining = totalBytes - doneBytes
        if let free = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
            free < remaining + (200 << 20)
        {
            phase = .failed("needs \(Self.format(remaining + (200 << 20))) free on this iPhone")
            return
        }
        do {
            try prepareFiles()
        } catch {
            phase = .failed("couldn't create the model files: \(error.localizedDescription)")
            return
        }
        UserDefaults.standard.set(true, forKey: Self.startedKey)
        UserDefaults.standard.set(false, forKey: Self.pausedKey)
        phase = .downloading
        note = nil
        startSpeedSampling()
        if !ModelSpec.isUITest {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        log.notice("download start: \(self.done.count)/\(self.chunks.count) chunks done")
        enqueueMissing()
    }

    func pause() {
        guard phase == .downloading else { return }
        UserDefaults.standard.set(true, forKey: Self.pausedKey)
        phase = .paused
        note = nil
        speedTask?.cancel()
        bytesPerSecond = 0
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
        inFlight.removeAll()
        receivedBytes = doneBytes
        log.notice("download paused at \(self.receivedBytes) bytes")
    }

    /// deletes the model and its download state (settings → delete model)
    func deleteModel() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
        try? FileManager.default.removeItem(at: Self.modelDirectory)
        UserDefaults.standard.removeObject(forKey: Self.startedKey)
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
        done = []
        inFlight = [:]
        receivedBytes = 0
        phase = .notStarted
    }

    // MARK: - tasks

    private func enqueueMissing() {
        session.getAllTasks { tasks in
            let running = Set(tasks.filter { $0.state == .running || $0.state == .suspended }
                .compactMap(\.taskDescription))
            Task { @MainActor in
                guard self.phase == .downloading else { return }
                let missing = self.chunks.filter { !self.done.contains($0.key) && !running.contains($0.key) }
                if self.chunks.allSatisfy({ self.done.contains($0.key) }) {
                    // a range fetched twice (e.g. re-queued after a relaunch) may still be running
                    tasks.forEach { $0.cancel() }
                    self.finish()
                    return
                }
                for (index, chunk) in missing.enumerated() {
                    // the UI tests' small files would arrive before the test can press pause: space them out
                    self.enqueue(chunk, after: ModelSpec.isUITest ? Double(index) * 0.25 : 0)
                }
            }
        }
    }

    private func enqueue(_ chunk: Chunk, after delay: TimeInterval = 0) {
        guard let file = spec.files.first(where: { $0.name == chunk.file }) else { return }
        var request = URLRequest(url: spec.url(for: file))
        request.setValue("bytes=\(chunk.offset)-\(chunk.offset + chunk.length - 1)", forHTTPHeaderField: "Range")
        let task = session.downloadTask(with: request)
        task.taskDescription = chunk.key
        task.countOfBytesClientExpectsToReceive = chunk.length
        if delay > 0 {
            task.earliestBeginDate = Date().addingTimeInterval(delay)
        }
        task.resume()
    }

    private func chunkFinished(_ chunk: Chunk) {
        inFlight[chunk.key] = nil
        retryCounts[chunk.key] = nil
        done.insert(chunk.key)
        Self.saveDone(done)
        receivedBytes = doneBytes + inFlight.values.reduce(0, +)
        note = nil
        if phase == .downloading, chunks.allSatisfy({ done.contains($0.key) }) {
            enqueueMissing()
        }
    }

    private func chunkFailed(_ chunk: Chunk, reason: String) {
        inFlight[chunk.key] = nil
        receivedBytes = doneBytes + inFlight.values.reduce(0, +)
        guard phase == .downloading else { return }
        let tries = (retryCounts[chunk.key] ?? 0) + 1
        retryCounts[chunk.key] = tries
        note = "retrying: \(reason)"
        log.error("chunk \(chunk.key) failed (\(tries)): \(reason)")
        // back off up to a minute; background sessions also wait for the network by themselves
        let delay = min(60, 2 << min(tries, 5))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard self.phase == .downloading, !self.done.contains(chunk.key) else { return }
            self.enqueue(chunk)
        }
    }

    // MARK: - finishing

    private func finish() {
        guard phase == .downloading else { return }
        phase = .verifying
        speedTask?.cancel()
        bytesPerSecond = 0
        let files = spec.files
        Task.detached(priority: .userInitiated) {
            let result = Self.verify(files)
            await MainActor.run {
                switch result {
                case .success:
                    FileManager.default.createFile(atPath: Self.readyFile.path, contents: Data())
                    try? FileManager.default.removeItem(at: Self.doneFile)
                    self.receivedBytes = self.totalBytes
                    self.phase = .ready
                    log.notice("model ready")
                    self.notifyIfInBackground()
                case .failure(let error):
                    // a bad file is downloaded again from scratch
                    for name in error.files {
                        try? FileManager.default.removeItem(at: Self.modelDirectory.appending(path: name))
                    }
                    self.done = self.done.filter { key in !error.files.contains { key.hasPrefix("\($0)|") } }
                    Self.saveDone(self.done)
                    self.receivedBytes = self.doneBytes
                    self.phase = .failed("the download was damaged (\(error.files.joined(separator: ", "))); tap resume to fetch it again")
                }
            }
        }
    }

    struct VerifyError: Error {
        let files: [String]
    }

    nonisolated private static func verify(_ files: [ModelFile]) -> Result<Void, VerifyError> {
        var bad: [String] = []
        for file in files {
            let url = modelDirectory.appending(path: file.name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
            guard size == file.size else {
                bad.append(file.name)
                continue
            }
            guard let expected = file.sha256 else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                bad.append(file.name)
                continue
            }
            var hasher = SHA256()
            var more = true
            while more {
                // each block is freed as soon as it is hashed; without the pool the 5 GB file piles up in memory
                // and iOS kills the app
                autoreleasepool {
                    if let block = try? handle.read(upToCount: 8 << 20), !block.isEmpty {
                        hasher.update(data: block)
                    } else {
                        more = false
                    }
                }
            }
            try? handle.close()
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if digest != expected {
                log.error("\(file.name) sha256 \(digest) != \(expected)")
                bad.append(file.name)
            }
        }
        return bad.isEmpty ? .success(()) : .failure(VerifyError(files: bad))
    }

    private func notifyIfInBackground() {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Lantern is ready"
        content.body = "\(spec.displayName) finished downloading. Tap to start chatting."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "model-ready", content: content, trigger: nil))
    }

    // MARK: - files

    /// Creates each model file at its full size (sparse on APFS), so ranges can be written at their offsets.
    private func prepareFiles() throws {
        var dir = Self.modelDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        for file in spec.files {
            let url = Self.modelDirectory.appending(path: file.name)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                done = done.filter { !$0.hasPrefix("\(file.name)|") }
            }
            let handle = try FileHandle(forWritingTo: url)
            if try handle.seekToEnd() != UInt64(file.size) {
                try handle.truncate(atOffset: UInt64(file.size))
            }
            try handle.close()
        }
        Self.saveDone(done)
    }

    nonisolated private static func write(_ chunk: Chunk, from location: URL) throws {
        let data = try Data(contentsOf: location, options: .mappedIfSafe)
        guard Int64(data.count) == chunk.length else {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "got \(data.count) of \(chunk.length) bytes"])
        }
        let handle = try FileHandle(forWritingTo: modelDirectory.appending(path: chunk.file))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(chunk.offset))
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    nonisolated private static func loadDone() -> Set<String> {
        guard let data = try? Data(contentsOf: doneFile),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    nonisolated private static func saveDone(_ done: Set<String>) {
        if let data = try? JSONEncoder().encode(done.sorted()) {
            try? data.write(to: doneFile, options: .atomic)
        }
    }

    // MARK: - speed

    private func startSpeedSampling() {
        speedTask?.cancel()
        speedSample = (Date(), receivedBytes)
        speedTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let sample = speedSample else { continue }
                let now = Date()
                let rate = Double(receivedBytes - sample.bytes) / now.timeIntervalSince(sample.time)
                // smooth over a few seconds so the time left doesn't jump around
                bytesPerSecond = bytesPerSecond == 0 ? max(0, rate) : 0.8 * bytesPerSecond + 0.2 * max(0, rate)
                speedSample = (now, receivedBytes)
            }
        }
    }

    var secondsLeft: Double? {
        guard bytesPerSecond > 1 else { return nil }
        return Double(totalBytes - receivedBytes) / bytesPerSecond
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - URLSession delegate

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL)
    {
        guard let key = downloadTask.taskDescription, let chunk = Chunk(key: key) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        let range = response?.value(forHTTPHeaderField: "Content-Range") ?? ""
        let wholeFile = status == 200 && chunk.offset == 0
        let expectedRange = "bytes \(chunk.offset)-\(chunk.offset + chunk.length - 1)/"
        guard wholeFile || (status == 206 && range.hasPrefix(expectedRange)) else {
            Task { @MainActor in self.chunkFailed(chunk, reason: "server answered \(status) \(range)") }
            return
        }
        // the file at `location` is gone once this returns, so it is written here, synchronously
        do {
            try Self.write(chunk, from: location)
            Task { @MainActor in self.chunkFinished(chunk) }
        } catch {
            Task { @MainActor in self.chunkFailed(chunk, reason: error.localizedDescription) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64)
    {
        guard let key = downloadTask.taskDescription else { return }
        Task { @MainActor in
            guard self.phase == .downloading, !self.done.contains(key) else { return }
            self.inFlight[key] = totalBytesWritten
            self.receivedBytes = self.doneBytes + self.inFlight.values.reduce(0, +)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = task.taskDescription, let chunk = Chunk(key: key) else { return }
        if (error as? URLError)?.code == .cancelled { return }
        Task { @MainActor in self.chunkFailed(chunk, reason: error.localizedDescription) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
