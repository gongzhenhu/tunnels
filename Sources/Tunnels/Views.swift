import ServiceManagement
import SwiftUI

struct MenuView: View {
    let store: TunnelStore
    @Bindable var ui: UIState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.menuHosts, id: \.self) { host in
                SectionHeader(title: host)
                ForEach(store.specs(for: host)) { spec in
                    if let runner = store.runners[spec.id] {
                        TunnelRow(
                            spec: spec,
                            runner: runner,
                            conflict: store.conflict(for: spec),
                            expanded: ui.expandedID == spec.id,
                            editing: Binding(
                                get: { ui.editingID == spec.id },
                                set: { ui.editingID = $0 ? spec.id : nil }),
                            onExpand: { closeForm(); toggleExpanded(spec.id) },
                            onToggle: { closeForm(); store.setEnabled(spec.id, $0) },
                            onResolve: { store.resolveConflict(spec, $0) },
                            onUpdate: { store.update(spec.id, local: $0, remote: $1) },
                            onDelete: { store.delete(spec.id) }
                        )
                    }
                }
            }

            if ui.adding || store.specs.isEmpty {
                AddTunnelForm(store: store, ui: ui)
                    .padding(.top, store.specs.isEmpty ? 0 : 6)
            } else {
                AddRow { ui.adding = true }
                    .padding(.top, 2)
            }

            if !store.externals.isEmpty {
                SectionHeader(title: "外部进程")
                ForEach(store.externals) { ext in
                    ExternalRow(
                        tunnel: ext,
                        onAdopt: { closeForm(); store.adopt(ext) },
                        onTerminate: { closeForm(); store.terminate(ext) }
                    )
                }
            }

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            footer
        }
        .padding(6)
        .frame(width: 320)
        // 收起表单和展开的详情（已填的内容保留在 draft 里）：点空白处、菜单失去焦点
        .background { BlankArea(action: collapseTransient) }
        .background(MenuWindowObserver(onHide: collapseTransient))
    }

    /// 在表单以外做任何操作，都先收起表单
    private func closeForm() {
        guard ui.adding else { return }
        withAnimation(.snappy(duration: 0.2)) { ui.adding = false }
    }

    private func collapseTransient() {
        guard ui.adding || ui.expandedID != nil || ui.editingID != nil else { return }
        withAnimation(.snappy(duration: 0.2)) {
            ui.adding = false
            ui.expandedID = nil
            ui.editingID = nil
        }
    }

    /// 设一次就不再碰的选项收进 ⋯，不常驻
    private var footer: some View {
        HStack {
            Spacer()
            Menu {
                Toggle("开机启动", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                Divider()
                Button("退出") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func toggleExpanded(_ id: UUID) {
        withAnimation(.snappy(duration: 0.2)) {
            ui.expandedID = ui.expandedID == id ? nil : id
            ui.editingID = nil
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        try? on ? service.register() : service.unregister()
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        launchAtLogin = service.status == .enabled
    }
}

/// 菜单关闭或失去焦点时通知。
/// 菜单打开时不一定是 key window（只有新建表单会主动激活），所以“失去焦点”不够，
/// 还要看窗口是否已从屏幕上消失（occlusion 变为不可见）。
private struct MenuWindowObserver: NSViewRepresentable {
    let onHide: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onHide = onHide
    }

    final class ObserverView: NSView {
        var onHide: () -> Void = {}
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
                    [weak self] _ in self?.onHide()
                },
                center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) {
                    [weak self, weak window] _ in
                    if let window, !window.occlusionState.contains(.visible) { self?.onHide() }
                },
            ]
        }

        private func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        deinit { removeObservers() }
    }
}

/// 铺在背景上的透明按钮，点到没有控件的地方时触发。
/// 菜单栏面板里 onTapGesture 收不到点击，只有 Button 能收到，所以用它来接“点空白处”。
private struct BlankArea: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 行

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

private struct RowChrome: ViewModifier {
    let highlighted: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(highlighted ? Color.primary.opacity(0.07) : .clear)
            )
    }
}

/// 与状态点等宽的首列，保证各行文字左对齐
private let leadColumn: CGFloat = 10

struct StatusDot: View {
    enum Tone { case off, ok, busy, warn, error }

    let tone: Tone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        switch tone {
        case .off: return .clear
        case .ok: return .green
        case .busy, .warn: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        Group {
            if tone == .busy && !reduceMotion {
                // 呼吸效果只作用在圆点自身；不能用 withAnimation(.repeatForever)，
                // 那会把同一时刻的其他布局变化（如菜单弹出）也卷进无限动画，导致整个菜单一直跳
                dot.phaseAnimator([1.0, 0.3]) { content, opacity in
                    content.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.8)
                }
            } else {
                dot
            }
        }
        .frame(width: leadColumn)
    }

    private var dot: some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(tone == .off ? Color.secondary : .clear, lineWidth: 1))
            .frame(width: 7, height: 7)
    }
}

/// 本机在左、服务器在右，箭头指向被访问的一方；左栏定宽让各行箭头对齐成一列
private struct MappingLabel: View {
    let local: String
    let remote: String
    let towardServer: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("本机 \(local)")
                .frame(width: 78, alignment: .leading)
            Image(systemName: towardServer ? "arrow.right" : "arrow.left")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("服务器 \(remote)")
        }
        .monospacedDigit()
        .lineLimit(1)
    }
}

private struct TunnelRow: View {
    let spec: TunnelSpec
    let runner: TunnelRunner
    let conflict: ExternalTunnel?
    let expanded: Bool
    @Binding var editing: Bool
    let onExpand: () -> Void
    let onToggle: (Bool) -> Void
    let onResolve: (ExternalTunnel) -> Void
    /// 返回错误信息，nil 表示成功
    let onUpdate: (Int, Int) -> String?
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var editLocal = ""
    @State private var editRemote = ""
    @State private var editError: String?

    /// 只有处于端口冲突重试时，占用者才相关
    private var blocker: ExternalTunnel? {
        guard case .retrying(let reason, _) = runner.phase, reason.contains("占用") else { return nil }
        return conflict
    }

    private var tone: StatusDot.Tone {
        switch runner.phase {
        case .off: return .off
        case .connecting: return .busy
        case .connected: return runner.upstreamDown ? .warn : .ok
        case .retrying: return .warn
        case .failed: return .error
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onExpand) {
                    HStack(spacing: 8) {
                        StatusDot(tone: tone)
                        VStack(alignment: .leading, spacing: 1) {
                            MappingLabel(local: String(spec.localPort), remote: String(spec.remotePort),
                                         towardServer: spec.kind == .forward)
                                .foregroundStyle(spec.enabled ? .primary : .secondary)
                            if hasStatus {
                                status
                                    .font(.caption)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(accessibilityTitle)，\(TunnelStore.statusText(runner))")
                .accessibilityHint(expanded ? "收起详情" : "展开详情")
                if hovering, runner.isConnected, let url = spec.url {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderless)
                    .help("在浏览器打开")
                    .accessibilityLabel("在浏览器打开")
                }
                Button(action: onExpand) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || expanded ? 1 : 0)
                .accessibilityHidden(true)  // 与整行按钮重复
                Toggle(accessibilityTitle, isOn: Binding(get: { spec.enabled }, set: onToggle))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            if expanded { detail }
        }

        .modifier(RowChrome(highlighted: hovering || expanded))
        .onHover { hovering = $0 }
    }

    /// 读屏用：方向说成“谁访问谁”，比箭头好懂
    private var accessibilityTitle: String {
        let mapping = spec.kind == .forward
            ? "本机 \(spec.localPort) 访问服务器 \(spec.remotePort)"
            : "服务器 \(spec.remotePort) 访问本机 \(spec.localPort)"
        return mapping
    }

    /// 正常（已连接、已关闭）时只占一行，有事才出第二行
    private var hasStatus: Bool {
        switch runner.phase {
        case .off: return false
        case .connected: return runner.upstreamDown
        default: return true
        }
    }

    @ViewBuilder
    private var status: some View {
        switch runner.phase {
        case .off:
            EmptyView()
        case .connecting:
            Text("连接中…").foregroundStyle(.secondary)
        case .connected:
            Text("本机 \(String(spec.localPort)) 未在监听").foregroundStyle(.orange)
        case .retrying where blocker != nil:
            Text(verbatim: "端口被\(blocker!.ownerPhrase)占用")
                .truncationMode(.middle)
                .foregroundStyle(.orange)
        case .retrying(let reason, let at):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(at.timeIntervalSince(context.date).rounded(.up)))
                Text(seconds > 0 ? "\(reason)，\(seconds) 秒后重试" : "\(reason)，重试中")
                    .foregroundStyle(.orange)
            }
        case .failed(let reason):
            Text(reason).foregroundStyle(.red)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !runner.log.isEmpty {
                ScrollView {
                    Text(runner.log.suffix(15).joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 110)
            }
            if editing { editor } else { actions }
        }
        .padding(.leading, leadColumn + 8)
        // 详情内部的空白不算点空白
        .background { BlankArea {} }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                PortField(label: "本机", text: $editLocal, placeholder: String(spec.localPort), onSubmit: save)
                Image(systemName: spec.kind == .forward ? "arrow.right" : "arrow.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                PortField(label: "服务器", text: $editRemote, placeholder: String(spec.remotePort), onSubmit: save)
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                if let editError {
                    Text(editError).foregroundStyle(.red)
                }
                Spacer()
                Button("取消") { editing = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedEdit == nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    /// 留空表示不改
    private var parsedEdit: (Int, Int)? {
        func parse(_ s: String, _ current: Int) -> Int? {
            if s.isEmpty { return current }
            guard let p = Int(s), (1...65535).contains(p) else { return nil }
            return p
        }
        guard let l = parse(editLocal, spec.localPort), let r = parse(editRemote, spec.remotePort) else { return nil }
        return (l, r)
    }

    private func startEditing() {
        NSApp.activate()
        editLocal = String(spec.localPort)
        editRemote = String(spec.remotePort)
        editError = nil
        editing = true
    }

    private func save() {
        guard let (l, r) = parsedEdit else { return }
        editError = onUpdate(l, r)
        if editError == nil { editing = false }
    }

    private var actions: some View {
            HStack(spacing: 12) {
                if case .connected(let since) = runner.phase {
                    Text("已连接 \(since, style: .relative)").foregroundStyle(.tertiary)
                }
                if let pid = runner.pid {
                    Text(verbatim: "进程 \(pid)").foregroundStyle(.tertiary)
                }
                Spacer()
                if let blocker, blocker.canTerminate {
                    Button("结束占用进程") { onResolve(blocker) }
                }
                Button("修改端口", action: startEditing)
                Button("复制命令") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(spec.shellCommand, forType: .string)
                }
                Button("删除", role: .destructive, action: onDelete)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .font(.caption)
    }
}

private struct ExternalRow: View {
    let tunnel: ExternalTunnel
    let onAdopt: () -> Void
    let onTerminate: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(tone: .ok)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(tunnel.forwards, id: \.self) { f in
                    MappingLabel(local: f.localSide, remote: f.remoteSide, towardServer: f.towardServer)
                }
                Text(verbatim: "\(tunnel.host)，\(tunnel.origin.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            // 有守护者的进程不给操作入口：结束了也会被重新拉起
            if hovering && tunnel.canTerminate {
                if tunnel.canAdopt {
                    Button("接管", action: onAdopt)
                        .help("结束这个进程，改由 Tunnels 托管同样的端口")
                }
                Button(action: onTerminate) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .help("结束进程")
                .accessibilityLabel("结束进程")
            }
        }
        .buttonStyle(.borderless)
        .font(.body)
        .modifier(RowChrome(highlighted: hovering && tunnel.canTerminate))
        .onHover { hovering = $0 }
        .help("\(tunnel.tool) 进程 \(String(tunnel.pid))")
    }
}

private struct AddRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: leadColumn)
                Text("新建隧道")
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新建隧道")
        .modifier(RowChrome(highlighted: hovering))
        .onHover { hovering = $0 }
    }
}

/// 端口输入框：新建表单和修改端口共用。占位符显示留空时会用的值
private struct PortField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 62)
                .onSubmit(onSubmit)
        }
    }
}

// MARK: - 新建

private struct AddTunnelForm: View {
    let store: TunnelStore
    @Bindable var ui: UIState
    @State private var loading = false
    @State private var loadError: String?

    private var spec: TunnelSpec? {
        let local = Int(ui.draft.local), remote = Int(ui.draft.remote)
        let fallbackLocal = ui.draft.kind == .reverse ? TunnelSpec.defaultReverseLocalPort : remote
        guard !ui.draft.host.isEmpty,
              let l = local ?? fallbackLocal, let r = remote ?? local,
              (1...65535).contains(l), (1...65535).contains(r) else { return nil }
        return TunnelSpec(host: ui.draft.host, kind: ui.draft.kind, localPort: l, remotePort: r)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $ui.draft.kind) {
                    Text("转发").tag(TunnelKind.forward)
                    Text("反向").tag(TunnelKind.reverse)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("方向")
                .fixedSize()
                .help("转发：本机访问服务器上的服务；反向：服务器访问本机的服务")
                Spacer()
                if store.hosts.isEmpty {
                    TextField("主机", text: $ui.draft.host)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                } else {
                    Picker("", selection: $ui.draft.host) {
                        ForEach(store.hosts, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .accessibilityLabel("主机")
                    .frame(maxWidth: 150)
                }
            }

            HStack(spacing: 6) {
                PortField(label: "本机", text: $ui.draft.local,
                          placeholder: ui.draft.kind == .reverse ? String(TunnelSpec.defaultReverseLocalPort) : ui.draft.remote,
                          onSubmit: submit)
                Image(systemName: ui.draft.kind == .forward ? "arrow.right" : "arrow.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                PortField(label: "服务器", text: $ui.draft.remote, placeholder: ui.draft.local, onSubmit: submit)
                Spacer(minLength: 0)
            }

            if ui.draft.kind == .forward { suggestions }

            HStack {
                Spacer()
                if !store.specs.isEmpty {
                    Button("取消") { ui.adding = false }
                        .keyboardShortcut(.cancelAction)
                }
                Button("开启", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(spec == nil)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        // 表单内部的空白不算点空白
        .background { BlankArea {} }
        .onAppear {
            NSApp.activate()
            store.reloadHosts()
            if !store.hosts.isEmpty && !store.hosts.contains(ui.draft.host) {
                ui.draft.host = store.hosts.contains(store.lastHost) ? store.lastHost : store.hosts[0]
            }
        }
        .task(id: "\(ui.draft.host)|\(ui.draft.kind.rawValue)") { await loadPorts() }
    }

    @ViewBuilder
    private var suggestions: some View {
        let ports = ui.remotePorts[ui.draft.host] ?? []
        let mine = ports.filter { $0.program != nil && $0.port < 32768 }
        // 1024 以下是 ssh、邮件之类的系统服务，转发没有意义
        let others = ports.filter { !mine.contains($0) && $0.port >= 1024 }

        if ports.isEmpty {
            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在读取服务器端口")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } else {
            let shown = ui.showAllPorts ? mine + others : mine
            VStack(alignment: .leading, spacing: 6) {
                if ui.showAllPorts {
                    // 菜单面板按内容定尺寸，ScrollView 必须给明确高度，否则会被压扁
                    ScrollView { portGrid(shown) }
                        .frame(height: min(140, gridHeight(rows: shown.count)))
                } else {
                    portGrid(shown)
                }

                if !others.isEmpty {
                    Button(ui.showAllPorts ? "只看我的进程" : "其他 \(others.count) 个端口") {
                        ui.showAllPorts.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    private static let gridColumns = 3
    private static let chipHeight: CGFloat = 20
    private static let chipSpacing: CGFloat = 4

    private func portGrid(_ ports: [RemotePort]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.chipSpacing), count: Self.gridColumns),
                  alignment: .leading, spacing: Self.chipSpacing) {
            ForEach(ports) { chip($0) }
        }
    }

    private func gridHeight(rows count: Int) -> CGFloat {
        let rows = CGFloat((count + Self.gridColumns - 1) / Self.gridColumns)
        return rows * Self.chipHeight + max(0, rows - 1) * Self.chipSpacing
    }

    private func chip(_ port: RemotePort) -> some View {
        let selected = ui.draft.remote == String(port.port)
        return Button {
            ui.draft.remote = String(port.port)
        } label: {
            HStack(spacing: 4) {
                Text(String(port.port)).monospacedDigit()
                if let program = port.program {
                    Text(program)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.caption)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: Self.chipHeight, maxHeight: Self.chipHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(port.program.map { "服务器端口 \(port.port)，\($0)" } ?? "服务器端口 \(port.port)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func loadPorts() async {
        let host = ui.draft.host
        guard ui.draft.kind == .forward, !host.isEmpty else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            ui.remotePorts[host] = try await RemotePorts.fetch(host: host)
        } catch {
            if ui.remotePorts[host] == nil { loadError = error.localizedDescription }
        }
    }

    private func submit() {
        guard let spec else { return }
        store.lastHost = spec.host
        store.setEnabled(store.upsert(spec).id, true)
        ui.draft.local = ""
        ui.draft.remote = ""
        ui.adding = false
    }
}

