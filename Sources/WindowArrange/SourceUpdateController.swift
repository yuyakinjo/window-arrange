import AppKit
import CoreServices
import Darwin

/// Watches the source tree the app was built from and, on request, rebuilds and relaunches it
/// through `scripts/update.ts`. Inactive unless the bundle was stamped by `scripts/build.ts`.
@MainActor
final class SourceUpdateController: ObservableObject {
    enum State: Equatable {
        case unavailable, upToDate, available, updating
        case failed(String)
    }

    struct Configuration: Equatable {
        var root: URL
        var bun: URL
        var fingerprint: String
        var buildConfiguration: String
        var app: URL
        var log: URL { root.appendingPathComponent(".local/update.log") }
        var script: URL { root.appendingPathComponent("scripts/update.ts") }
    }

    @Published private(set) var state: State = .unavailable
    let configuration: Configuration?
    private var stream: FSEventStreamRef?
    private var pendingCheck: DispatchWorkItem?
    private var checking = false
    private var recheck = false
    private var updateExit: DispatchSourceProcess?
    private var termination: DispatchSourceSignal?

    init(configuration: Configuration? = SourceUpdateController.configuration(
        info: Bundle.main.infoDictionary ?? [:], bundle: Bundle.main.bundleURL, arguments: CommandLine.arguments)) {
        self.configuration = configuration
    }

    /// Development mode already rebuilds on save, so the update button stays out of the way there.
    nonisolated static func configuration(info: [String: Any], bundle: URL, arguments: [String],
                                          fileManager: FileManager = .default) -> Configuration? {
        guard !arguments.contains("--development"), bundle.pathExtension == "app",
              let root = info["WindowArrangeSourceRoot"] as? String, !root.isEmpty,
              let bun = info["WindowArrangeBunPath"] as? String, !bun.isEmpty,
              let fingerprint = info["WindowArrangeSourceFingerprint"] as? String, !fingerprint.isEmpty,
              let build = info["WindowArrangeBuildConfiguration"] as? String, ["debug", "release"].contains(build)
        else { return nil }
        let configuration = Configuration(root: URL(fileURLWithPath: root, isDirectory: true),
                                          bun: URL(fileURLWithPath: bun), fingerprint: fingerprint,
                                          buildConfiguration: build, app: bundle)
        guard fileManager.fileExists(atPath: configuration.script.path),
              fileManager.isExecutableFile(atPath: bun) else { return nil }
        return configuration
    }

    /// Only paths that `scripts/source.ts` fingerprints trigger a check; build output churn is ignored.
    nonisolated static func isRelevant(_ path: String, root: URL) -> Bool {
        let base = root.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return false }
        let relative = String(path.dropFirst(prefix.count))
        if relative == "Package.swift" || relative == "package.json" { return true }
        let first = relative.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return ["Sources", "Resources", "scripts"].contains(first)
    }

    func start() {
        guard let configuration, stream == nil else { return }
        state = .upToDate
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let controller = Unmanaged<SourceUpdateController>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated { controller.received(Array(list.prefix(count))) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [configuration.root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        // Sources may have changed while the app was not running (e.g. git pull).
        check()
    }

    func stop() {
        pendingCheck?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func received(_ paths: [String]) {
        guard let configuration, paths.contains(where: { Self.isRelevant($0, root: configuration.root) }) else { return }
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func check() {
        guard let configuration, state != .updating else { return }
        if checking { recheck = true; return }
        checking = true
        Task {
            let current = await Self.currentFingerprint(configuration)
            checking = false
            if state != .updating, let current {
                if current != configuration.fingerprint { state = .available }
                else if case .failed = state {} else { state = .upToDate }
            }
            if recheck { recheck = false; check() }
        }
    }

    private nonisolated static func currentFingerprint(_ configuration: Configuration) async -> String? {
        await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = configuration.bun
            process.arguments = [configuration.script.path, "--check"]
            process.currentDirectoryURL = configuration.root
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    /// Starts the detached updater. On success it terminates this app, swaps the bundle and relaunches it;
    /// on failure the app keeps running and shows the log.
    func update() {
        guard let configuration, state != .updating else { return }
        installGracefulTermination()
        do {
            let pid = try Self.spawnUpdater(configuration)
            state = .updating
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                self?.updaterExited(status: status)
            }
            source.resume()
            updateExit = source
        } catch {
            state = .failed("更新を開始できませんでした: \(error.localizedDescription)")
        }
    }

    func showLog() {
        guard let configuration, FileManager.default.fileExists(atPath: configuration.log.path) else { return }
        NSWorkspace.shared.open(configuration.log)
    }

    private func updaterExited(status: Int32) {
        updateExit?.cancel()
        updateExit = nil
        // A successful update terminates this process first; reaching here means it did not.
        let succeeded = (status & 0x7f) == 0 && ((status >> 8) & 0xff) == 0
        state = .failed(succeeded ? "更新後の再起動を確認できませんでした。" : "ビルドに失敗しました。ログを確認してください。")
    }

    /// The updater stops the app with SIGTERM; quit normally so cleanup in applicationWillTerminate runs.
    private func installGracefulTermination() {
        guard termination == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termination = source
    }

    private nonisolated static func spawnUpdater(_ configuration: Configuration) throws -> pid_t {
        try FileManager.default.createDirectory(at: configuration.log.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let arguments = [configuration.bun.path, configuration.script.path, "--app", configuration.app.path,
                         "--configuration", configuration.buildConfiguration]
        var environment = ProcessInfo.processInfo.environment
        let path = [configuration.bun.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                    environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["PATH"] = path.joined(separator: ":")

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, configuration.log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session keeps the updater alive after it terminates this app.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, configuration.bun.path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return pid
    }
}
