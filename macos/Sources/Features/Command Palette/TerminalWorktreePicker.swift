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
                            placeholder: "Go to worktree…",
                            selectsFirstOption: true,
                            options: worktreeOptions
                        )
                        .zIndex(1)

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            if !newValue {
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
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
                sectionTitle: isLive ? "Active Branches" : "Inactive Branches",
                isDimmed: !isLive,
                titleWeight: worktree.isMain ? .semibold : .regular
            ) {
                onSelect(worktree)
            }
        }
    }
}
