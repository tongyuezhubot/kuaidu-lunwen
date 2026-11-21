import AppKit
import SwiftUI
import Combine

@MainActor final class ReadingToolbar: NSObject, NSToolbarDelegate {
    private let model: Workspace
    private var titleObserver: AnyCancellable?
    private let sidebar = NSToolbarItem.Identifier("LibrarySidebar")
    private let actions = NSToolbarItem.Identifier("DocumentActions")

    init(window: NSWindow, model: Workspace) {
        self.model = model
        super.init()
        let toolbar = NSToolbar(identifier: "Reading")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        titleObserver = model.$surface.combineLatest(model.$current, model.$papers).sink { [weak window] surface, id, papers in
            guard let window else { return }
            let paper = surface == .reader ? papers.first(where: { $0.id == id }) : nil
            window.title = paper?.title ?? (surface == .starred ? "星标文献" : "全部文献")
            window.subtitle = paper.map { $0.sample ? "示例文献" : $0.filename } ?? ""
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [sidebar, .flexibleSpace, actions] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case sidebar:
            item.label = "文献库侧栏"
            item.toolTip = "显示或隐藏文献库"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
            item.isNavigational = true
            item.target = self
            item.action = #selector(toggleSidebar)
        case actions:
            item.label = "文献操作"
            item.view = NSHostingView(rootView: DocumentActions(m: model).fixedSize())
        default: return nil
        }
        return item
    }
    @objc private func toggleSidebar() { model.showSidebar.toggle() }
}

private struct DocumentActions: View {
    @ObservedObject var m: Workspace
    var body: some View {
        HStack(spacing: 13) {
            Menu {
                Picker("阅读外观", selection: $m.appearance) {
                    ForEach(ReadingAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.inline)
                Divider()
                Toggle("保留 PDF 原色", isOn: $m.originalPageColors)
            } label: {
                Image(systemName: "circle.lefthalf.filled").frame(width: 19)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("阅读外观与 PDF 配色").accessibilityLabel("阅读外观")
            if m.surface == .reader, let paper = m.target {
                Button { m.beginManualNote() } label: { Label("手动批注", systemImage: "pencil.tip") }
                    .help("选中同页原文后添加批注（⌘⇧A）").disabled(m.document == nil)
                Button { m.sheet = .importNotes } label: { Label("导入批注", systemImage: "square.and.arrow.down") }
                Menu {
                    Button("框选并批注…") { m.selectingRegion = .new }.disabled(m.document == nil)
                    Divider()
                    Button(paper.starred ? "取消星标" : "添加星标") { m.star(paper.id) }
                    Divider()
                    Button("导出批注 JSON…") { m.exportNotes(false) }
                    Button("导出带高光的 PDF…") { m.exportNotes(true) }.disabled(m.locating || m.document == nil)
                    Divider()
                    Button("清除本篇 AI 批注…") { m.confirmClearAINotes(in: paper) }
                        .disabled(!paper.notes.contains { !$0.isManual })
                    Button("从文献库移除…") { m.remove(paper) }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多文献操作").accessibilityLabel("更多文献操作")
                Divider().frame(height: 15)
                ToolIcon(icon: "sidebar.right", label: m.showNotes ? "收起阅读批注" : "显示阅读批注") { m.showNotes.toggle() }
            } else {
                Button { m.choosePDF() } label: { Label("导入 PDF", systemImage: "plus") }
            }
        }.labelStyle(.titleAndIcon).font(.system(size: 12, weight: .medium))
            .buttonStyle(.borderless).foregroundStyle(.primary).frame(height: 32)
    }
}
