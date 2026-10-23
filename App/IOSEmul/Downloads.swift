import CryptoKit
import Foundation
import UIKit
import EmulatorKit

/// One IPSW being fetched from Apple's CDN.
struct FirmwareDownloadItem: Identifiable, Hashable {
    enum State: Hashable {
        case running
        /// Downloaded; checking the file against the SHA-1 ipsw.me lists before importing it.
        case verifying
        case failed(String)
    }

    let id: Int                 // URLSessionTask.taskIdentifier
    let url: URL
    let title: String
    var written: Int64 = 0
    var expected: Int64 = 0
    var state: State = .running

    var fraction: Double? { expected > 0 ? Double(written) / Double(expected) : nil }
    var fileName: String { url.lastPathComponent }
}

/// Downloads IPSWs listed by ipsw.me into Documents/Firmware and imports them into the library.
///
/// IPSWs are several GiB, so the transfers run in a background URLSession: they continue while
/// the app is suspended, and a transfer that drops keeps its resume data so Retry picks up where it
/// stopped instead of starting over.
@MainActor
final class DownloadManager: ObservableObject {
    nonisolated static let sessionIdentifier = "com.iosemul.app.firmware-downloads"
    nonisolated static let directory = Library.documents.appendingPathComponent("Firmware", isDirectory: true)

    @Published private(set) var items: [FirmwareDownloadItem] = []
    @Published var lastError: String?

    /// Called with each finished file, on the main actor.
    var onFinished: ((URL) -> Void)?

    private var session: URLSession!
    private let relay = SessionRelay()
    private var resumeData: [URL: Data] = [:]

    /// SHA-1 of each IPSW being downloaded, by URL; kept across launches like the transfers.
    private static let checksumsKey = "firmwareChecksums"
    private var checksums: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.checksumsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.checksumsKey) }
    }

    init() {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        session = URLSession(configuration: config, delegate: relay, delegateQueue: nil)
        relay.manager = self
        // Transfers started before the app was last closed are still running in the system.
        session.getAllTasks { tasks in
            Task { @MainActor in
                for case let task as URLSessionDownloadTask in tasks where task.state == .running || task.state == .suspended {
                    guard let url = task.originalRequest?.url, !self.items.contains(where: { $0.id == task.taskIdentifier })
                    else { continue }
                    self.items.append(FirmwareDownloadItem(id: task.taskIdentifier, url: url,
                                                           title: task.taskDescription ?? url.lastPathComponent,
                                                           written: task.countOfBytesReceived,
                                                           expected: task.countOfBytesExpectedToReceive))
                }
            }
        }
    }

    func isActive(_ url: URL) -> Bool { items.contains { $0.url == url && $0.state == .running } }

    nonisolated static func localFile(for url: URL) -> URL { directory.appendingPathComponent(url.lastPathComponent) }

    /// Starts fetching `firmware` unless it is already downloading or there is no room for it.
    func start(_ firmware: FirmwareCatalog.Firmware, title: String) {
        guard !isActive(firmware.url) else { return }
        if let size = firmware.filesize, let free = Self.freeSpace(), free < size {
            let fmt = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            lastError = "\(firmware.fileName) needs \(fmt(size)); only \(fmt(free)) is free."
            return
        }
        items.removeAll { $0.url == firmware.url }
        if Pref.defaults.bool(forKey: Pref.verifyDownloads), let sha1 = firmware.sha1sum, !sha1.isEmpty {
            checksums[firmware.url.absoluteString] = sha1.lowercased()
        }
        let task = resumeData.removeValue(forKey: firmware.url).map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: Self.request(for: firmware.url))
        task.taskDescription = title
        if let size = firmware.filesize { task.countOfBytesClientExpectsToReceive = size }
        items.append(FirmwareDownloadItem(id: task.taskIdentifier, url: firmware.url, title: title,
                                          expected: firmware.filesize ?? 0))
        task.resume()
    }

    func retry(_ item: FirmwareDownloadItem) {
        items.removeAll { $0.id == item.id }
        let task = resumeData.removeValue(forKey: item.url).map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: Self.request(for: item.url))
        task.taskDescription = item.title
        items.append(FirmwareDownloadItem(id: task.taskIdentifier, url: item.url, title: item.title,
                                          written: item.written, expected: item.expected))
        task.resume()
    }

    func cancel(_ item: FirmwareDownloadItem) {
        items.removeAll { $0.id == item.id }
        resumeData[item.url] = nil
        session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == item.id }?.cancel() }
    }

    /// Mobile data only when Settings allows it: IPSWs are several GB.
    nonisolated static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = Pref.defaults.bool(forKey: Pref.cellularDownloads)
        return request
    }

    nonisolated static func freeSpace() -> Int64? {
        let values = try? Library.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Session events (from SessionRelay, already on the main actor)

    fileprivate func progress(task: Int, written: Int64, expected: Int64) {
        guard let i = items.firstIndex(where: { $0.id == task }) else { return }
        items[i].written = written
        if expected > 0 { items[i].expected = expected }
    }

    fileprivate func finished(task: Int, url: URL, file: URL) {
        guard let expected = checksums[url.absoluteString] else {
            items.removeAll { $0.id == task }
            onFinished?(file)
            return
        }
        if let i = items.firstIndex(where: { $0.id == task }) { items[i].state = .verifying }
        Task {
            let actual = await Task.detached(priority: .utility) { Self.sha1(of: file) }.value
            checksums[url.absoluteString] = nil
            if actual == expected {
                items.removeAll { $0.id == task }
                onFinished?(file)
            } else {
                // A damaged IPSW fails later with CRC errors deep inside a component; drop it now.
                try? FileManager.default.removeItem(at: file)
                checksums[url.absoluteString] = expected
                resumeData[url] = nil
                if let i = items.firstIndex(where: { $0.id == task }) {
                    items[i].state = .failed("The downloaded file is damaged (SHA-1 mismatch). Retry downloads it again.")
                }
            }
        }
    }

    /// Lowercase hex SHA-1 of a file, read in chunks (IPSWs are several GiB).
    nonisolated static func sha1(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    fileprivate func failed(task: Int, url: URL?, error: Error) {
        let nsError = error as NSError
        if let url, let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData[url] = data
        }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled,
           nsError.userInfo[NSURLSessionDownloadTaskResumeData] == nil {
            items.removeAll { $0.id == task }        // cancelled by the user
            return
        }
        guard let i = items.firstIndex(where: { $0.id == task }) else { return }
        items[i].state = .failed(error.localizedDescription)
    }

    fileprivate func failedToSave(task: Int, error: Error) {
        guard let i = items.firstIndex(where: { $0.id == task }) else { return }
        items[i].state = .failed("Could not save the file: \(error.localizedDescription)")
    }
}

/// URLSession delegate. Callbacks arrive on the session's queue; the downloaded file must be moved
/// before `didFinishDownloadingTo` returns, everything else is forwarded to the main actor.
private final class SessionRelay: NSObject, URLSessionDownloadDelegate {
    weak var manager: DownloadManager?
    private let throttle = ProgressThrottle()

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        // URLSession reports every received chunk, hundreds of times a second; redrawing the
        // download list that often made the whole app stutter.
        guard throttle.shouldReport(key: id, done: totalBytesWritten == totalBytesExpectedToWrite) else { return }
        Task { @MainActor in
            self.manager?.progress(task: id, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        // A transfer resumed from resume data finishes with 206 Partial Content.
        if let http = downloadTask.response as? HTTPURLResponse, ![200, 206].contains(http.statusCode) {
            let error = URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            Task { @MainActor in self.manager?.failedToSave(task: id, error: error) }
            return
        }
        guard let url = downloadTask.originalRequest?.url else { return }
        let destination = DownloadManager.localFile(for: url)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: DownloadManager.directory, withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            Task { @MainActor in self.manager?.finished(task: id, url: url, file: destination) }
        } catch {
            Task { @MainActor in self.manager?.failedToSave(task: id, error: error) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskIdentifier, url = task.originalRequest?.url
        Task { @MainActor in self.manager?.failed(task: id, url: url, error: error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            AppDelegate.backgroundCompletion?()
            AppDelegate.backgroundCompletion = nil
        }
    }
}

/// Lets progress through a few times a second per key; always lets the final report through.
/// Called from background threads.
final class ProgressThrottle: @unchecked Sendable {
    private let interval: TimeInterval
    private var last: [AnyHashable: TimeInterval] = [:]
    private let lock = NSLock()

    init(interval: TimeInterval = 0.25) { self.interval = interval }

    func shouldReport(key: AnyHashable = 0, done: Bool = false) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        if !done, let previous = last[key], now - previous < interval { return false }
        last[key] = now
        return true
    }
}

/// Receives the system's wake-up when background downloads finish while the app is not running.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var backgroundCompletion: (() -> Void)?

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionIdentifier else { return completionHandler() }
        Task { @MainActor in AppDelegate.backgroundCompletion = completionHandler }
    }
}
