import Foundation

/// Watches a repository's git *common* directory so the sidebar can refresh
/// when the repository changes underneath it.
///
/// The sidebar labels each row with its worktree's branch, and the palette
/// lists local branches that have no worktree — both go stale the moment
/// something changes the repo from the terminal. Every such operation writes
/// inside the common git directory:
///
/// - `git switch` / `git checkout` rewrites `HEAD` (the main worktree's, or
///   `worktrees/<id>/HEAD` for a linked one — which is why we watch the shared
///   common dir rather than just the current worktree's `.git`).
/// - `git branch` / `git branch -d` writes under `refs/heads/`.
/// - `git worktree add` / `remove` writes under `worktrees/`.
///
/// Watching that one directory therefore covers the whole family of drift with
/// a single event-driven source — no polling, and nothing to spawn.
///
/// Events are coalesced: a single git command touches several files (lock file,
/// the ref, the reflog), so firing per-event would trigger a burst of redundant
/// refreshes. `onChange` is delivered on the main queue.
final class GitDirectoryWatcher {
    private var stream: FSEventStreamRef?
    private var watchedPath: URL?
    private var pendingRefresh: DispatchWorkItem?

    private let debounceInterval: TimeInterval
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.eulee.wtty.git-directory-watcher")

    init(debounceInterval: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        // Tear down directly rather than via stop(): deinit can run off the
        // main actor and the FSEvents teardown is thread-agnostic.
        teardownStream()
    }

    /// Begin watching `path`, replacing any current watch. Passing nil stops
    /// watching. Re-watching the same path is a no-op so callers can call this
    /// freely (e.g. after every refresh) without churning the stream.
    func watch(_ path: URL?) {
        guard watchedPath != path else { return }
        stop()

        guard let path,
              FileManager.default.fileExists(atPath: path.path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<GitDirectoryWatcher>
                .fromOpaque(info)
                .takeUnretainedValue()
                .scheduleChange()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceInterval,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        self.stream = stream
        self.watchedPath = path
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        teardownStream()
        pendingRefresh?.cancel()
        pendingRefresh = nil
        watchedPath = nil
    }

    private func teardownStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleChange() {
        pendingRefresh?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onChange() }
        }
        pendingRefresh = item
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }
}
