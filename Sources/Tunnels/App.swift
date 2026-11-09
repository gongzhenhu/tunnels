import SwiftUI

struct TunnelsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: delegate.store, ui: delegate.ui)
        } label: {
            StatusIcon(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = TunnelStore()
    let ui = UIState()
    private var server: ControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.bootstrap()
        ui.draft.host = store.lastHost
        server = ControlServer { [unowned self] req in
            req.cmd == "snapshot" ? self.snapshot(req.args ?? []) : await self.store.handle(req)
        }
        server?.start()
    }

    /// 离屏渲染菜单内容，用于检查界面（不需要屏幕录制权限）
    private func snapshot(_ args: [String]) -> ControlResponse {
        guard let path = args.first else { return ControlResponse(ok: false, message: "缺少输出路径") }
        let saved = (ui.adding, ui.expandedID, ui.showAllPorts, ui.editingID)
        ui.adding = args.contains("add")
        ui.showAllPorts = args.contains("all")
        if args.contains("expand") {
            ui.expandedID = store.specs.first { store.runners[$0.id]?.needsAttention == true }?.id ?? store.specs.first?.id
        }
        if args.contains("edit") { ui.editingID = ui.expandedID }
        defer { (ui.adding, ui.expandedID, ui.showAllPorts, ui.editingID) = saved }

        let host = NSHostingView(rootView: MenuView(store: store, ui: ui)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: args.contains("dark") ? .darkAqua : .aqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return ControlResponse(ok: false, message: "渲染失败")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        } catch {
            return ControlResponse(ok: false, message: error.localizedDescription)
        }
        return ControlResponse(ok: true, message: path)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.shutdown()
    }
}

/// 菜单关闭再打开时需要保留的界面状态
@MainActor @Observable
final class UIState {
    struct Draft {
        var kind: TunnelKind = .forward
        var host = ""
        var local = ""
        var remote = ""
        var name = ""
    }

    var adding = false
    var draft = Draft()
    var expandedID: UUID?
    var editingID: UUID?
    var showAllPorts = false
    var remotePorts: [String: [RemotePort]] = [:]
}

struct StatusIcon: View {
    let store: TunnelStore

    var body: some View {
        switch store.overall {
        case .idle: Image(systemName: "point.3.connected.trianglepath.dotted")
        case .active: Image(systemName: "point.3.filled.connected.trianglepath.dotted")
        case .attention: Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}
