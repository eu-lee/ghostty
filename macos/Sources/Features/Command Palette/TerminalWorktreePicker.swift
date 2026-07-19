import SwiftUI

struct TerminalWorktreePickerView: View {
    let surfaceView: Ghostty.SurfaceView
    @Binding var isPresented: Bool
    @ObservedObject var ghosttyConfig: Ghostty.Config
    @ObservedObject var viewModel: WorktreeSidebarViewModel
    var onSelect: (Worktree) -> Void

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            placeholder: "Worktree or branch…",
                            selectsFirstOption: true,
                            options: worktreeOptions + branchOptions,
                            trailingOption: createBranchOption(query:),
                            errorMessage: viewModel.createError,
                            maxWidth: paletteWidth(for: geometry.size.width)
                        )
                        .zIndex(1)

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            if newValue {
                viewModel.clearCreateError()
            } else {
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    /// Palette width scaled to the terminal, echoing Spotlight's proportions:
    /// a comfortable fraction of the window that grows and shrinks with it, but
    /// clamped so it never gets cramped on a small window or absurdly wide on a
    /// large one.
    private func paletteWidth(for containerWidth: CGFloat) -> CGFloat {
        min(max(containerWidth * 0.6, 480), 760)
    }

    private var worktreeOptions: [CommandOption] {
        WorktreeSidebar.activeFirst(
            viewModel.worktrees,
            activeWorktreePaths: viewModel.activeWorktreePaths
        )
        .map { worktree in
            let isLive = viewModel.isLive(worktree)
            let title = WorktreeSidebar.displayName(for: worktree)
            return CommandOption(
                title: title,
                subtitle: worktree.path.path,
                description: worktree.path.path,
                leadingColor: isLive ? Color.accentColor : Color.secondary.opacity(0.35),
                sectionTitle: "Worktrees",
                isDimmed: !isLive,
                titleWeight: worktree.isMain ? .semibold : .regular
            ) {
                onSelect(worktree)
            }
        }
    }

    private var branchOptions: [CommandOption] {
        viewModel.branchesWithoutWorktree.map { branch in
            CommandOption(
                title: branch,
                subtitle: viewModel.isCreatingWorktree ? "Opening…" : "Open existing branch",
                description: branch,
                leadingIcon: "arrow.triangle.branch",
                sectionTitle: "Branches",
                isDimmed: true,
                dismissOnSelect: false
            ) {
                Task { @MainActor in
                    await viewModel.openExistingBranch(branch)
                    if viewModel.createError == nil {
                        isPresented = false
                    }
                }
            }
        }
    }

    private func createBranchOption(query: String) -> CommandOption? {
        let branch = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return nil }
        guard !existingNames.contains(branch) else { return nil }

        return CommandOption(
            title: "Create branch '\(branch)'…",
            subtitle: viewModel.isCreatingWorktree ? "Creating…" : createSubtitle,
            description: branch,
            leadingIcon: "plus.circle",
            sectionTitle: "Create",
            emphasis: true,
            dismissOnSelect: false
        ) {
            Task { @MainActor in
                await viewModel.createWorktree(branch: branch)
                if viewModel.createError == nil {
                    isPresented = false
                }
            }
        }
    }

    private var createSubtitle: String {
        if let base = viewModel.defaultBaseBranch {
            return "Create from \(base)"
        }
        return "Create from repository HEAD"
    }

    private var existingNames: Set<String> {
        let worktreeNames = viewModel.worktrees.flatMap { worktree in
            [WorktreeSidebar.displayName(for: worktree), worktree.branch].compactMap(\.self)
        }
        return Set(worktreeNames + viewModel.branchesWithoutWorktree)
    }
}
