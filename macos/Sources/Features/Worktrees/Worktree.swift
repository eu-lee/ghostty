import Foundation
import OSLog

#if os(macOS)

struct Worktree: Equatable {
    let path: URL
    let branch: String?
    let isMain: Bool
    let isDetached: Bool
}

func repoRoot(forCwd cwd: URL) async -> URL? {
    await GitWorktreeModel().repoRoot(forCwd: cwd)
}

func worktrees(forCwd cwd: URL) async -> [Worktree] {
    await GitWorktreeModel().worktrees(forCwd: cwd)
}

func localBranches(forCwd cwd: URL) async -> [String] {
    await GitWorktreeModel().localBranches(forCwd: cwd)
}

func remoteBranches(forCwd cwd: URL) async -> [RemoteBranch] {
    await GitWorktreeModel().remoteBranches(forCwd: cwd)
}

/// A remote-tracking ref (`refs/remotes/<remote>/<name>`) that a fetch has
/// already brought down.
///
/// These are read-only mirrors: git force-updates all of `refs/remotes/*` on
/// every fetch, and HEAD can only advance a ref under `refs/heads/*`. So
/// working on one means first creating a local branch that points at it —
/// which is exactly what the palette does, via
/// `git worktree add <dest> -b <name> <remote>/<name>`.
struct RemoteBranch: Equatable {
    /// The full short ref as git prints it (e.g. `origin/feat/x`). This is the
    /// start point handed to `git worktree add`.
    let ref: String

    /// The remote this ref came from (e.g. `origin`).
    let remote: String

    /// The branch name with the remote stripped — the local branch to create.
    let name: String

    /// Parse a `%(refname:short)` remote ref. Returns nil for anything that
    /// isn't a branch we can check out, notably `<remote>/HEAD` (a symbolic
    /// alias for the remote's default branch, not a branch of its own).
    init?(shortRef: String) {
        let ref = shortRef.trimmingCharacters(in: .whitespaces)
        guard let slash = ref.firstIndex(of: "/") else { return nil }

        let remote = String(ref[ref.startIndex..<slash])
        let name = String(ref[ref.index(after: slash)...])
        guard !remote.isEmpty, !name.isEmpty, name != "HEAD" else { return nil }

        self.ref = ref
        self.remote = remote
        self.name = name
    }
}

/// Why `git worktree add` failed, carrying what the sidebar needs to render
/// an unobtrusive error message (never an alert — see M4 guide).
enum WorktreeCreateError: Error, Equatable {
    /// The source cwd is not inside a git repository.
    case notARepository

    /// git exited nonzero; the associated value is its trimmed stderr.
    case git(String)

    case timedOut
    case launchFailed(String)

    /// A short, user-facing message for the sidebar. git's stderr usually
    /// leads with "fatal: " or "error: " — strip that noise but keep the
    /// substance (e.g. "invalid reference: my bad name").
    var message: String {
        switch self {
        case .notARepository:
            return "Not a git repository"
        case .git(let stderr):
            let cleaned = stderr
                .lines
                .map { line in
                    var line = line
                    for prefix in ["fatal: ", "error: "] where line.hasPrefix(prefix) {
                        line = String(line.dropFirst(prefix.count))
                    }
                    return line
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? "git worktree add failed" : cleaned
        case .timedOut:
            return "git worktree add timed out"
        case .launchFailed(let message):
            return "Could not launch git: \(message)"
        }
    }
}

/// The outcome of loading the sidebar's data for a directory, classified so a
/// transient git failure can be told apart from an authoritative "this is not a
/// repository". The distinction is load-bearing: a timeout or lock race must
/// never blank a repo the user is sitting in (see `GitWorktreeModel.load`).
enum WorktreeLoad: Equatable {
    /// `rev-parse` confirmed a repository and its worktrees were enumerated.
    case repository(worktrees: [Worktree], localBranches: [String], remoteBranches: [RemoteBranch])

    /// `git` authoritatively reported the directory is not in a repository
    /// (exit 128, "not a git repository"). Safe to show the empty state.
    case notARepository

    /// The state could not be determined — a timeout, a launch failure, an
    /// index/ref lock race, or any other nonzero status. The caller must keep
    /// its last-good state rather than blanking the sidebar.
    case unavailable
}

struct GitWorktreeModel {
    var runner: GitCommandRunning = GitProcessRunner()
    /// Read queries run on every git-directory change and window focus, so they
    /// race routine terminal git activity (shell prompts, helper tools, a
    /// concurrent `git` holding `index.lock`). Keep this generous enough that a
    /// busy machine doesn't spuriously time out and trip `.unavailable`.
    var timeout: TimeInterval = 5

    /// `git worktree add` checks out a full working copy, which on a large
    /// repository takes far longer than the read-only queries above.
    var createTimeout: TimeInterval = 30

    /// Create a worktree for a new branch named `branch`, at the conventional
    /// path `../<repo>-worktrees/<branch>` next to the main repository root
    /// (see `WorktreeSidebar.newWorktreePath`). If `base` is non-nil it is
    /// passed as git's explicit start point; otherwise git uses the repo
    /// root's HEAD. Branch/base validation is git's job: a bad value surfaces
    /// as `.git` with git's own message.
    func createWorktree(
        branch: String,
        from base: String? = nil,
        forCwd cwd: URL
    ) async -> Result<URL, WorktreeCreateError> {
        guard let root = await repoRoot(forCwd: cwd) else {
            return .failure(.notARepository)
        }

        let destination = WorktreeSidebar.newWorktreePath(repoRoot: root, branch: branch)
        var arguments = ["worktree", "add", destination.path, "-b", branch]
        if let base {
            arguments.append(base)
        }

        let result = await runner.runGit(
            arguments: arguments,
            cwd: root,
            timeout: createTimeout
        )

        switch result {
        case .success:
            return .success(destination)
        case .failure(_, let stderr):
            logFailure(result, command: "worktree add", cwd: root)
            return .failure(.git(stderr))
        case .timedOut:
            logFailure(result, command: "worktree add", cwd: root)
            return .failure(.timedOut)
        case .launchFailed(let message):
            logFailure(result, command: "worktree add", cwd: root)
            return .failure(.launchFailed(message))
        }
    }

    /// Add a linked worktree for an already-existing local branch. Unlike
    /// `createWorktree`, this intentionally does not pass `-b` or a start
    /// point; git checks out the branch as-is.
    func addWorktree(
        forExistingBranch branch: String,
        forCwd cwd: URL
    ) async -> Result<URL, WorktreeCreateError> {
        guard let root = await repoRoot(forCwd: cwd) else {
            return .failure(.notARepository)
        }

        let destination = WorktreeSidebar.newWorktreePath(repoRoot: root, branch: branch)
        let arguments = ["worktree", "add", destination.path, branch]

        let result = await runner.runGit(
            arguments: arguments,
            cwd: root,
            timeout: createTimeout
        )

        switch result {
        case .success:
            return .success(destination)
        case .failure(_, let stderr):
            logFailure(result, command: "worktree add", cwd: root)
            return .failure(.git(stderr))
        case .timedOut:
            logFailure(result, command: "worktree add", cwd: root)
            return .failure(.timedOut)
        case .launchFailed(let message):
            logFailure(result, command: "worktree add", cwd: root)
            return .failure(.launchFailed(message))
        }
    }

    /// Remove a linked worktree from disk via `git worktree remove`.
    /// Branch deletion is deliberately out of scope: git removes only the
    /// worktree checkout, leaving its branch reusable.
    func removeWorktree(
        path: URL,
        force: Bool = false,
        forCwd cwd: URL
    ) async -> Result<Void, WorktreeCreateError> {
        guard let root = await repoRoot(forCwd: cwd) else {
            return .failure(.notARepository)
        }

        var arguments = ["worktree", "remove", path.path]
        if force {
            arguments.append("--force")
        }

        let result = await runner.runGit(
            arguments: arguments,
            cwd: root,
            timeout: createTimeout
        )

        switch result {
        case .success:
            return .success(())
        case .failure(_, let stderr):
            logFailure(result, command: "worktree remove", cwd: root)
            return .failure(.git(stderr))
        case .timedOut:
            logFailure(result, command: "worktree remove", cwd: root)
            return .failure(.timedOut)
        case .launchFailed(let message):
            logFailure(result, command: "worktree remove", cwd: root)
            return .failure(.launchFailed(message))
        }
    }

    /// Load everything the sidebar needs in a single classification pass, so a
    /// transient git failure is distinguished from an authoritative "not a git
    /// repository". One `rev-parse` decides the repo state; enumerating the
    /// worktrees confirms it. Any failure that isn't an authoritative non-repo
    /// yields `.unavailable`, and the caller keeps its last-good state rather
    /// than collapsing a live repo to the empty state.
    func load(forCwd cwd: URL) async -> WorktreeLoad {
        let rootResult = await runner.runGit(
            arguments: ["rev-parse", "--git-common-dir"],
            cwd: cwd,
            timeout: timeout
        )

        let root: URL
        switch rootResult {
        case .success(let output):
            guard let firstLine = output.lines.first, !firstLine.isEmpty else {
                logger.warning("git rev-parse --git-common-dir returned no path for \(cwd.path, privacy: .public)")
                return .unavailable
            }
            root = worktreeRoot(fromCommonGitDir: absoluteURL(forGitPath: firstLine, relativeTo: cwd))
        case .failure(let status, let stderr):
            // Only git's own authoritative verdict (exit 128, "not a git
            // repository") empties the sidebar. Every other nonzero status is
            // treated as transient so a blip never blanks a live repo.
            if status == 128, stderr.lowercased().contains("not a git repository") {
                return .notARepository
            }
            logFailure(rootResult, command: "rev-parse --git-common-dir", cwd: cwd)
            return .unavailable
        case .timedOut, .launchFailed:
            logFailure(rootResult, command: "rev-parse --git-common-dir", cwd: cwd)
            return .unavailable
        }

        // It is a repository. Enumerating its worktrees is the one call whose
        // failure we can't paper over, so a failure here is transient →
        // `.unavailable` (never an empty repository).
        let listResult = await runner.runGit(
            arguments: ["worktree", "list", "--porcelain"],
            cwd: root,
            timeout: timeout
        )
        guard case .success(let porcelain) = listResult else {
            logFailure(listResult, command: "worktree list --porcelain", cwd: root)
            return .unavailable
        }
        let worktrees = WorktreePorcelainParser.parse(porcelain)

        // Branch lists only feed the palette's "no worktree" sections. If they
        // blip, prefer showing the worktrees without supplementary branch rows
        // over failing the whole load, so a repo the user is in stays put.
        let local = await forEachRef(["refs/heads"], root: root)
        let remote = await forEachRef(["--sort=-committerdate", "refs/remotes"], root: root)
            .compactMap { RemoteBranch(shortRef: $0) }

        return .repository(worktrees: worktrees, localBranches: local, remoteBranches: remote)
    }

    /// Run `for-each-ref --format=%(refname:short)` with the given extra args,
    /// returning the short refs or an empty list on failure (branch lists are
    /// supplementary — see `load`).
    private func forEachRef(_ extraArgs: [String], root: URL) async -> [String] {
        let result = await runner.runGit(
            arguments: ["for-each-ref", "--format=%(refname:short)"] + extraArgs,
            cwd: root,
            timeout: timeout
        )
        guard case .success(let output) = result else {
            logFailure(result, command: "for-each-ref \(extraArgs.joined(separator: " "))", cwd: root)
            return []
        }
        return output.lines
    }

    func repoRoot(forCwd cwd: URL) async -> URL? {
        let result = await runner.runGit(
            arguments: ["rev-parse", "--git-common-dir"],
            cwd: cwd,
            timeout: timeout
        )

        guard case .success(let output) = result else {
            logFailure(result, command: "rev-parse --git-common-dir", cwd: cwd)
            return nil
        }

        guard let firstLine = output.lines.first, !firstLine.isEmpty else {
            logger.warning("git rev-parse --git-common-dir returned no path for \(cwd.path, privacy: .public)")
            return nil
        }

        let commonDir = absoluteURL(forGitPath: firstLine, relativeTo: cwd)
        return worktreeRoot(fromCommonGitDir: commonDir)
    }

    func worktrees(forCwd cwd: URL) async -> [Worktree] {
        guard let root = await repoRoot(forCwd: cwd) else { return [] }

        let result = await runner.runGit(
            arguments: ["worktree", "list", "--porcelain"],
            cwd: root,
            timeout: timeout
        )

        guard case .success(let output) = result else {
            logFailure(result, command: "worktree list --porcelain", cwd: root)
            return []
        }

        return WorktreePorcelainParser.parse(output)
    }

    func localBranches(forCwd cwd: URL) async -> [String] {
        guard let root = await repoRoot(forCwd: cwd) else { return [] }

        let result = await runner.runGit(
            arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            cwd: root,
            timeout: timeout
        )

        guard case .success(let output) = result else {
            logFailure(result, command: "for-each-ref refs/heads", cwd: root)
            return []
        }

        return output.lines
    }

    /// Every remote-tracking branch, most recently committed first. Repos with
    /// hundreds of stale remote branches are common, and recency is the only
    /// ordering that reliably floats the interesting ones to the top — the
    /// palette shows a bounded slice of this list until the user types.
    func remoteBranches(forCwd cwd: URL) async -> [RemoteBranch] {
        guard let root = await repoRoot(forCwd: cwd) else { return [] }

        let result = await runner.runGit(
            arguments: [
                "for-each-ref",
                "--format=%(refname:short)",
                "--sort=-committerdate",
                "refs/remotes",
            ],
            cwd: root,
            timeout: timeout
        )

        guard case .success(let output) = result else {
            logFailure(result, command: "for-each-ref refs/remotes", cwd: root)
            return []
        }

        return output.lines.compactMap { RemoteBranch(shortRef: $0) }
    }

    private func logFailure(_ result: GitCommandResult, command: String, cwd: URL) {
        switch result {
        case .success:
            break
        case .failure(let status, let stderr):
            logger.warning(
                "git \(command, privacy: .public) failed in \(cwd.path, privacy: .public): status \(status), \(stderr, privacy: .public)"
            )
        case .timedOut:
            logger.warning("git \(command, privacy: .public) timed out in \(cwd.path, privacy: .public)")
        case .launchFailed(let message):
            logger.warning(
                "git \(command, privacy: .public) could not launch in \(cwd.path, privacy: .public): \(message, privacy: .public)"
            )
        }
    }
}

protocol GitCommandRunning {
    func runGit(arguments: [String], cwd: URL, timeout: TimeInterval) async -> GitCommandResult
}

enum GitCommandResult: Equatable {
    case success(String)
    case failure(status: Int32, stderr: String)
    case timedOut
    case launchFailed(String)
}

struct GitProcessRunner: GitCommandRunning {
    func runGit(arguments: [String], cwd: URL, timeout: TimeInterval) async -> GitCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runGitSynchronously(arguments: arguments, cwd: cwd, timeout: timeout))
            }
        }
    }
}

private func runGitSynchronously(arguments: [String], cwd: URL, timeout: TimeInterval) -> GitCommandResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    let semaphore = DispatchSemaphore(value: 0)

    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", cwd.path] + arguments
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
    } catch {
        return .launchFailed(error.localizedDescription)
    }

    let stdoutDrain = PipeDrain(stdout.fileHandleForReading)
    let stderrDrain = PipeDrain(stderr.fileHandleForReading)

    DispatchQueue.global(qos: .utility).async {
        process.waitUntilExit()
        semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        _ = semaphore.wait(timeout: .now() + 1)
        stdoutDrain.wait(timeout: .now() + 1)
        stderrDrain.wait(timeout: .now() + 1)
        return .timedOut
    }

    let output = String(data: stdoutDrain.data(), encoding: .utf8) ?? ""
    let error = String(data: stderrDrain.data(), encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        return .failure(status: process.terminationStatus, stderr: error.trimmedGitOutput)
    }

    return .success(output.trimmedGitOutput)
}

private struct WorktreePorcelainParser {
    static func parse(_ output: String) -> [Worktree] {
        let blocks = output
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // `git worktree list --porcelain` always emits the main working tree as
        // the first block. Identify main by that position rather than by
        // path-matching a separately-resolved repo root: a relative
        // `--git-common-dir` can make the match fail and flag no worktree as
        // main, which silently breaks main-pinning, removal guarding, and the
        // sidebar header.
        return blocks.enumerated().compactMap { index, block -> Worktree? in
            parseBlock(block, isMain: index == 0)
        }
    }

    private static func parseBlock(_ block: String, isMain: Bool) -> Worktree? {
        var path: URL?
        var branch: String?
        var isDetached = false

        for line in block.lines {
            if line.hasPrefix("worktree ") {
                path = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("branch ") {
                branch = branchName(fromRef: String(line.dropFirst("branch ".count)))
            } else if line == "detached" {
                isDetached = true
            }
        }

        guard let path else { return nil }

        if branch == nil && isDetached {
            branch = path.lastPathComponent
        }

        return Worktree(
            path: path,
            branch: branch,
            isMain: isMain,
            isDetached: isDetached
        )
    }

    private static func branchName(fromRef ref: String) -> String {
        let prefix = "refs/heads/"
        guard ref.hasPrefix(prefix) else { return ref }
        return String(ref.dropFirst(prefix.count))
    }
}

private final class PipeDrain {
    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.git-pipe-drain")
    private var bufferedData = Data()

    init(_ fileHandle: FileHandle) {
        group.enter()

        DispatchQueue.global(qos: .utility).async { [self] in
            let data = fileHandle.readDataToEndOfFile()

            self.queue.sync {
                self.bufferedData = data
            }

            self.group.leave()
        }
    }

    func data() -> Data {
        group.wait()
        return queue.sync { bufferedData }
    }

    func wait(timeout: DispatchTime) {
        _ = group.wait(timeout: timeout)
    }
}

private func absoluteURL(forGitPath path: String, relativeTo cwd: URL) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    return URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL
}

private func worktreeRoot(fromCommonGitDir commonDir: URL) -> URL {
    if commonDir.lastPathComponent == ".git" {
        return commonDir.deletingLastPathComponent().standardizedFileURL
    }

    return commonDir.standardizedFileURL
}

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
    category: "worktrees"
)

private extension String {
    var trimmedGitOutput: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var lines: [String] {
        split(whereSeparator: \.isNewline).map(String.init)
    }
}

#endif
