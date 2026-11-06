import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var firstClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // macOS 默认：点击不在前台的窗口时，第一下只会激活窗口，按钮不会响应。
        // 这里在事件分发前先把窗口设为前台，让第一下点击就能点中按钮。
        firstClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            if let w = event.window, !w.isKeyWindow, w.canBecomeKey, w.isVisible {
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                w.makeKey()
            }
            return event
        }
        if ProcessInfo.processInfo.environment["TM_LOG"] != nil {
            MainActor.assumeIsolated { AppLog.shared.echoToStdout = true }
            installDebugClickHook()
        }
        if CommandLine.arguments.contains("--selftest") {
            MainActor.assumeIsolated { SelfTest.run() }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 仅调试模式：收到分布式通知后，在主窗口指定位置合成一次真实的鼠标点击（走 AppKit 正常分发），用于自动化测试点击区域
    private func installDebugClickHook() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("TimeMachine.debugClick"), object: nil, queue: .main) { note in
            guard let s = note.object as? String else { return }
            let parts = s.split(separator: ",").compactMap { Double($0) }
            guard parts.count >= 2 else { return }
            let count = parts.count >= 3 ? Int(parts[2]) : 1
            MainActor.assumeIsolated {
                guard let w = AppModel.shared.mainWindow else { return }
                let loc = NSPoint(x: parts[0], y: w.frame.height - parts[1])
                for n in 1...max(1, count) {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1) {
                            NSApp.sendEvent(e)
                        }
                    }
                }
                log("调试点击：(\(Int(parts[0])), \(Int(parts[1])))")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.engine.saveNow() }
    }
}

@main
struct TimeMachineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("时光机", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands { AppCommands(model: model) }

        Window("抖音网页 · 登录与验证", id: "login") {
            LoginView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 640)
        }
        .defaultSize(width: 1080, height: 760)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("登录抖音…") { openWindow(id: "login") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandMenu("播放") {
            Button("下一条（↓ / J）") { model.next() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("上一条（↑ / K）") { model.previous() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("播放 / 暂停（空格）") { model.player.togglePlay() }
                .keyboardShortcut("p", modifiers: .command)
            Divider()
            Button("点赞（Z）") { model.toggleLike() }
            Button("评论（X）") { model.toggleComments() }
            Button("收藏（C）") { model.toggleCollect() }
            Button("作者主页（F）") { model.openAuthor() }
            Button("不感兴趣（N）") { model.notInterested() }
            Button(model.player.muted ? "取消静音（M）" : "静音（M）") { model.player.muted.toggle() }
            Divider()
            Button("复制视频链接") { model.copyLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("在浏览器中打开") { model.openInBrowser() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandMenu("穿越") {
            Button("出发（当前选择的时间段）") { model.travel() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("随机穿越") { model.randomTravel() }
                .keyboardShortcut("r", modifiers: .command)
            Button("继续寻找") { model.engine.continueSearching() }
                .keyboardShortcut("g", modifiers: .command)
            Button("重新扫描这个时间段") { model.engine.rescan() }
            Divider()
            Button("观看历史") { model.showHistory = true }
                .keyboardShortcut("y", modifiers: .command)
        }
    }
}
