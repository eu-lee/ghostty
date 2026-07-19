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

struct GitWorktreeModel {
    var runner: GitCommandRunning = GitProcessRunner()
    var timeout: TimeInterval = 2

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

        return WorktreePorcelainParser.parse(output, mainRoot: root)
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
    static func parse(_ output: String, mainRoot: URL) -> [Worktree] {
        let blocks = output
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let mainPath = normalizedPath(mainRoot)

        let parsed = blocks.compactMap { block -> Worktree? in
            parseBlock(block, mainPath: mainPath)
        }

        return parsed.filter(\.isMain) + parsed.filter { !$0.isMain }
    }

    private static func parseBlock(_ block: String, mainPath: String) -> Worktree? {
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
            isMain: normalizedPath(path) == mainPath,
            isDetached: isDetached
        )
    }

    private static func branchName(fromRef ref: String) -> String {
        let prefix = "refs/heads/"
        guard ref.hasPrefix(prefix) else { return ref }
        return String(ref.dropFirst(prefix.count))
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
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
