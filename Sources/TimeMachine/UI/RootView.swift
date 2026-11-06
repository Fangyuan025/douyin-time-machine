import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 290, ideal: 316, max: 380)
        } detail: {
            FeedStage()
                .inspector(isPresented: $model.showComments) {
                    CommentsPanel()
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
                }
        }
        .background(WindowAccessor { w in
            if model.mainWindow !== w { model.mainWindow = w }
        })
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .sheet(item: $model.authorSheet) { a in
            AuthorSheet(author: a).environment(model)
        }
        .sheet(isPresented: $model.showHistory) {
            HistorySheet().environment(model)
        }
        .overlay(alignment: .top) {
            if let t = model.toast {
                Text(t)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.ultraThickMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.12)))
                    .shadow(radius: 12)
                    .padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
        .onReceive(NotificationCenter.default.publisher(for: .openLoginWindow)) { _ in
            openWindow(id: "login")
        }
        .onAppear {
            if !CommandLine.arguments.contains("--selftest") { model.start() }
        }
    }
}

struct GradientButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? 14 : 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, prominent ? 10 : 7)
            .frame(maxWidth: .infinity)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Theme.accent.opacity(prominent ? 0.45 : 0.25), radius: prominent ? 10 : 5, y: 3)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
