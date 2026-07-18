import SwiftUI

struct TerminalNewWorktreeView: View {
    let surfaceView: Ghostty.SurfaceView
    @Binding var isPresented: Bool
    @ObservedObject var ghosttyConfig: Ghostty.Config
    @ObservedObject var viewModel: WorktreeSidebarViewModel

    @State private var branchName = ""
    @State private var baseRef = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case branch
        case base
    }

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        popup
                            .zIndex(1)

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            if newValue {
                branchName = ""
                baseRef = ""
                viewModel.clearCreateError()
                DispatchQueue.main.async {
                    focusedField = .branch
                }
            } else {
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    private var popup: some View {
        let scheme: ColorScheme = if OSColor(ghosttyConfig.backgroundColor).isLightColor {
            .light
        } else {
            .dark
        }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)

                TextField("New worktree branch name…", text: $branchName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .light))
                    .disabled(viewModel.isCreatingWorktree)
                    .focused($focusedField, equals: .branch)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancel)

                if viewModel.isCreatingWorktree {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: 48)
            .padding(.horizontal)

            Divider()

            HStack(spacing: 10) {
                Text("from")
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)

                TextField(viewModel.defaultBaseBranch ?? "main HEAD", text: $baseRef)
                    .textFieldStyle(.plain)
                    .disabled(viewModel.isCreatingWorktree)
                    .focused($focusedField, equals: .base)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancel)
            }
            .frame(height: 34)
            .padding(.horizontal)

            if let error = viewModel.createError {
                Divider()

                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .help(error)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: 500)
        .background(
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                Rectangle()
                    .fill(ghosttyConfig.backgroundColor)
                    .blendMode(.color)
            }
                .compositingGroup()
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.75))
        )
        .shadow(radius: 32, x: 0, y: 12)
        .padding()
        .environment(\.colorScheme, scheme)
    }

    private func submit() {
        let branch = branchName
        let base = baseRef
        guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !viewModel.isCreatingWorktree else { return }

        Task { @MainActor in
            await viewModel.createWorktree(branch: branch, base: base)

            if viewModel.createError == nil {
                isPresented = false
                branchName = ""
                baseRef = ""
            } else {
                focusedField = .branch
            }
        }
    }

    private func cancel() {
        isPresented = false
        branchName = ""
        baseRef = ""
        viewModel.clearCreateError()
    }
}
