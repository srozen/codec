import AppKit
import SwiftUI
import Combine
import CodecCore

/// Which tab the right sidebar shows.
enum InspectorTab: String {
    case commands, ports
}

/// The tabs above the right sidebar: Commands and Ports.
struct InspectorBar: View {
    @ObservedObject var model: WindowModel
    let theme: CodecTheme
    var select: (InspectorTab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            tab(.commands, title: "Commands", systemImage: "list.bullet.rectangle", shortcut: "⇧⌘L")
            tab(.ports, title: "Ports", systemImage: "network", shortcut: "⇧⌘O")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.foreground).opacity(theme.isDark ? 0.025 : 0.035))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.dividerColor).frame(height: 1) }
        .overlay(alignment: .leading) { Rectangle().fill(theme.dividerColor).frame(width: 1) }
    }

    private func tab(_ tab: InspectorTab, title: String, systemImage: String, shortcut: String) -> some View {
        let selected = model.inspectorTab == tab
        return Button { select(tab) } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(selected ? 0.09 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .help("\(title) (\(shortcut))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// What the Ports tab lists: every port the programs in any pane are listening on, this window's
/// first. Follows the panes only while the tab is showing.
@MainActor
final class PortsModel: ObservableObject {
    struct Row: Identifiable {
        let id: String
        let location: PortLocation

        var port: ListeningPort { location.port }

        /// Under the name: where the pane is, after the program when the process goes by a name of the user's.
        var detail: String {
            port.name == nil ? location.place : "\(port.program) · \(location.place)"
        }
    }

    struct Section: Identifiable {
        let id: Int
        /// The window the ports are in, when that needs saying: they're not all in this one.
        let title: String?
        let rows: [Row]
    }

    @Published private(set) var sections: [Section] = []
    /// The row whose process is being given a name.
    @Published var naming: String?

    private let directory: PaneDirectory
    /// The window the list is in.
    weak var host: (any PaneHost)?
    private var subscription: AnyCancellable?

    init(directory: PaneDirectory) {
        self.directory = directory
    }

    var rows: [Row] { sections.flatMap(\.rows) }

    /// Whether the tab is showing: it keeps up with the panes only then.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            // Sent once the change is made, so what's read here is already the new state.
            subscription = isActive ? directory.objectWillChange.sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            } : nil
            if isActive { reload(refreshing: true) } else { naming = nil }
        }
    }

    /// Lists the ports again; `refreshing` has every pane look at what it's listening on first.
    func reload(refreshing: Bool = false) {
        let windows = directory.listening(refreshing: refreshing)
        let ordered = windows.filter { $0.host === host } + windows.filter { $0.host !== host }
        let titled = ordered.contains { $0.host !== host }
        sections = ordered.enumerated().map { index, window in
            Section(id: index, title: titled ? (window.host === host ? "This Window" : window.title ?? "Another Window") : nil,
                    rows: window.ports.map { Row(id: "\($0.pane.session.id.uuidString):\($0.port.port)", location: $0) })
        }
        if let naming, !rows.contains(where: { $0.id == naming }) { self.naming = nil }
    }

    func goToPane(_ row: Row) {
        row.location.goToPane()
    }

    func openInBrowser(_ row: Row) {
        row.location.openInBrowser()
    }

    func copyAddress(_ row: Row) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.port.url.absoluteString, forType: .string)
    }

    /// Calls the row's process `name` for as long as it runs; a blank name takes its name away, and
    /// nil leaves it as it was.
    func finishNaming(_ row: Row, as name: String?) {
        naming = nil
        if let name { row.location.pane.name(row.port, as: name) }
    }
}

/// The Ports tab of the right sidebar: what's listening in every pane, with the way to each pane.
final class PortsSidebar: NSView {
    let model: PortsModel
    /// The user dragged the leading edge to this width.
    var onResize: ((CGFloat) -> Void)?

    private let list: NSHostingView<PortsList>
    private let divider = NSView()
    private let resizeHandle = SidebarResizeHandle()

    init(model: PortsModel, theme: CodecTheme) {
        self.model = model
        list = NSHostingView(rootView: PortsList(model: model, theme: theme))
        super.init(frame: .zero)
        wantsLayer = true
        divider.wantsLayer = true
        // The window sizes the sidebar, not what's listed in it.
        list.sizingOptions = []
        resizeHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            self.onResize?(self.frame.width - delta)
        }
        for view in [list, divider, resizeHandle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.centerXAnchor.constraint(equalTo: divider.centerXAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 8),
            list.topAnchor.constraint(equalTo: topAnchor),
            list.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: CodecTheme) {
        list.rootView = PortsList(model: model, theme: theme)
        layer?.backgroundColor = theme.foreground.withAlphaComponent(theme.isDark ? 0.025 : 0.035).cgColor
        divider.layer?.backgroundColor = theme.divider.cgColor
    }
}

/// The list: a heading, then each port with who's listening and where, a window at a time.
struct PortsList: View {
    @ObservedObject var model: PortsModel
    let theme: CodecTheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Listening")
                    .font(.system(size: 12, weight: .semibold))
                Text(Self.count(model.rows.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
            .padding(.leading, 12)
            .frame(height: 34)
            if model.sections.isEmpty {
                Text("Nothing is listening. Start a server in any pane, and its port shows up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.sections) { section in
                            if let title = section.title {
                                Label(title, systemImage: "macwindow")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                            }
                            ForEach(section.rows) { row in
                                PortRow(model: model, row: row, theme: theme)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// "1 port", "3 ports"; nothing for none, which the list says in full.
    static func count(_ count: Int) -> String {
        count == 0 ? "" : count == 1 ? "1 port" : "\(count) ports"
    }
}

/// One port: its number, the name its process goes by, and where its pane is. Click to go there.
private struct PortRow: View {
    @ObservedObject var model: PortsModel
    let row: PortsModel.Row
    let theme: CodecTheme
    @State private var hovering = false

    var body: some View {
        let naming = model.naming == row.id
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.port.label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if naming {
                    InlineNameEditor(initialName: row.port.name ?? "", placeholder: row.port.program, label: "Process name",
                                     onFinish: { model.finishNaming(row, as: $0) })
                } else {
                    Text(row.port.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(row.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if hovering, !naming {
                RowButton(systemImage: "pencil", help: row.port.name == nil ? "Name This Process" : "Rename") { model.naming = row.id }
                RowButton(systemImage: "safari", help: "Open \(row.port.url.absoluteString)") { model.openInBrowser(row) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.07 : 0)).padding(.horizontal, 6))
        .contentShape(Rectangle())
        .onTapGesture { if !naming { model.goToPane(row) } }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Go to Pane") { model.goToPane(row) }
            Button("Open in Browser") { model.openInBrowser(row) }
            Button("Copy Address") { model.copyAddress(row) }
            Divider()
            Button(row.port.name == nil ? "Name Process…" : "Rename…") { model.naming = row.id }
            if row.port.name != nil {
                Button("Remove Name") { model.finishNaming(row, as: "") }
            }
        }
        .help("Go to the pane: \(row.port.program) is listening on \(row.port.label) in \(row.location.place)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Port \(row.port.port), \(row.port.displayName), \(row.detail)")
        .accessibilityAddTraits(.isButton)
    }
}

private struct RowButton: View {
    let systemImage: String
    let help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}
