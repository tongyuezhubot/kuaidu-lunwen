import SwiftUI
import PDFKit

struct PanelButton: View {
    let text: String, icon: String
    var prominent = false
    let action: () -> Void
    var body: some View {
        let button = Button(action: action) { Label(text, systemImage: icon) }
        if prominent { button.buttonStyle(.borderedProminent).tint(C.accent) }
        else { button.buttonStyle(.bordered) }
    }
}

struct ToolIcon: View {
    let icon: String, label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .regular))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}

struct EmptyMessage: View {
    let icon: String, title: String, detail: String
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 25, weight: .light)).foregroundStyle(C.gray)
            Text(title).font(.headline)
            if !detail.isEmpty {
                Text(detail).foregroundStyle(C.gray).font(.callout).multilineTextAlignment(.center).lineSpacing(3)
            }
        }.padding(22).frame(maxWidth: .infinity)
    }
}

struct Shell: View {
    @ObservedObject var m: Workspace
    var body: some View {
        HStack(spacing: 0) {
            if m.showSidebar { Sidebar(m: m).frame(width: 172); Divider() }
            if m.surface == .reader, let paper = m.target { Reader(m: m, paper: paper) }
            else { CollectionView(m: m) }
        }
        .foregroundStyle(C.ink).tint(C.accent).background(C.paper)
        .overlay(alignment: .bottom) {
            if !m.toast.isEmpty {
                Text(m.toast).font(.callout).padding(.horizontal, 13).padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 1)
                    .padding(.bottom, 39).allowsHitTesting(false)
            }
        }
        .sheet(item: $m.sheet) { sheet in
            switch sheet {
            case .guide: Guide(m: m)
            case .importNotes: ImportNotes(m: m)
            case .manual(let paperID, let note, let isNew):
                ManualNoteEditor(m: m, paperID: paperID, isNew: isNew, draft: note)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) {
            Button("好") { m.error = nil }
        } message: { Text(m.error ?? "") }
    }
}

struct Sidebar: View {
    @ObservedObject var m: Workspace
    private func navigation(_ title: String, icon: String, surface: Surface, count: Int) -> some View {
        Button {
            m.surface = surface
            m.query = ""
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer()
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(C.gray)
            }
            .font(.system(size: 13)).padding(.horizontal, 9).frame(height: 31)
            .background(m.surface == surface ? C.selection : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("文献库").font(.system(size: 14, weight: .semibold))
                Spacer()
                ToolIcon(icon: "plus", label: "导入 PDF（⌘O）") { m.choosePDF() }
            }.padding(.horizontal, 8).padding(.top, 17).padding(.bottom, 10)
            navigation("全部文献", icon: "books.vertical", surface: .all, count: m.papers.count)
            navigation("星标文献", icon: "star", surface: .starred, count: m.papers.filter(\.starred).count)
            Text("最近阅读").font(.system(size: 11, weight: .medium)).foregroundStyle(C.gray)
                .padding(.leading, 9).padding(.top, 28).padding(.bottom, 7)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(m.papers.prefix(12)) { paper in
                        let active = m.surface == .reader && m.current == paper.id
                        Button { m.open(paper.id) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "doc.text").font(.system(size: 12)).padding(.top, 2)
                                    .foregroundStyle(active ? C.accent : C.gray)
                                Text(paper.title).font(.system(size: 12, weight: active ? .medium : .regular))
                                    .lineLimit(2).lineSpacing(2)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 9).padding(.vertical, 8)
                                .background(active ? C.selection : .clear, in: RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(paper.title)
                    }
                }
            }
            HStack {
                Button { m.sheet = .guide } label: { Label("批注指南", systemImage: "book") }
                    .buttonStyle(.plain).help("AI 批注指南与提示词")
                Spacer()
                ToolIcon(icon: "folder", label: "在访达中打开本地文献库") { NSWorkspace.shared.open(m.library.root) }
            }.font(.system(size: 12)).foregroundStyle(C.gray).padding(.horizontal, 8).padding(.vertical, 12)
        }.padding(.horizontal, 9).background(C.side)
    }
}

struct Reader: View {
    @ObservedObject var m: Workspace
    let paper: Paper
    var body: some View {
        GeometryReader { size in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if m.document != nil {
                        ZStack(alignment: .top) {
                            ReaderCanvas(m: m)
                            if m.selectingRegion != nil {
                                RegionSelection(m: m)
                                HStack(spacing: 12) {
                                    Text("在一页内拖框，选取公式或原文")
                                    Button("取消") { m.selectingRegion = nil }.keyboardShortcut(.cancelAction)
                                }.font(.callout).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                                    .padding(.top, 8)
                            }
                        }
                    }
                    else {
                        Spacer()
                        EmptyMessage(icon: "doc", title: "无法显示 PDF", detail: "请重新导入原文件。")
                        Spacer()
                    }
                    Divider()
                    HStack(spacing: 2) {
                        ToolIcon(icon: "chevron.left", label: "上一页") { m.goto(m.page-1) }.disabled(m.page <= 1)
                        Menu {
                            ForEach(1...max(1, paper.pages), id: \.self) { n in Button("第 \(n) 页") { m.goto(n) } }
                        } label: { Text("第 \(m.page) 页 / 共 \(paper.pages) 页").monospacedDigit() }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("跳转到页码")
                        ToolIcon(icon: "chevron.right", label: "下一页") { m.goto(m.page+1) }.disabled(m.page >= paper.pages)
                        Spacer()
                        ToolIcon(icon: "minus.magnifyingglass", label: "缩小") { m.viewer?.zoom(1/1.15) }
                        Button("\(m.scaling)%") { m.viewer?.fit() }.monospacedDigit().buttonStyle(.plain).help("适合宽度")
                        ToolIcon(icon: "plus.magnifyingglass", label: "放大") { m.viewer?.zoom(1.15) }
                    }.font(.system(size: 11)).foregroundStyle(C.gray).padding(.horizontal, 12).frame(height: 32)
                }.frame(maxWidth: .infinity).background(C.paper)
                if m.showNotes {
                    Divider()
                    NotesPane(m: m, paper: paper).frame(width: max(258, min(312, size.size.width * 0.30)))
                }
            }
        }
    }
}

private struct PageNotes: Identifiable {
    let page: Int?
    let notes: [Note]
    var id: Int { page ?? 0 }
}

struct NotesPane: View {
    @ObservedObject var m: Workspace
    let paper: Paper
    private func pageFor(_ note: Note) -> Int? {
        m.anchors[note.id]?.pageNumber ?? note.page
    }
    private var groups: [PageNotes] {
        let filtered = paper.notes.filter { note in
            switch m.filter {
            case .all: return true
            case .page: return pageFor(note) == m.page
            case .issues: return m.anchors[note.id]?.issue != nil
            }
        }
        return Dictionary(grouping: filtered, by: pageFor)
            .map { PageNotes(page: $0.key, notes: $0.value) }
            .sorted { ($0.page ?? .max) < ($1.page ?? .max) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("阅读批注").font(.custom("Songti SC Bold", size: 21))
                Text("\(paper.notes.count)").font(.system(size: 12, design: .serif)).foregroundStyle(C.gray)
            }.padding(.horizontal, 20).padding(.top, 20)
            HStack(spacing: 20) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Button { m.filter = f } label: {
                        Text(f.rawValue + (f == .issues && m.unresolved > 0 ? " \(m.unresolved)" : ""))
                            .font(.system(size: 12, weight: f == m.filter ? .semibold : .regular))
                            .foregroundStyle(f == m.filter ? C.ink : C.gray).frame(height: 35)
                            .overlay(alignment: .bottom) {
                                if f == m.filter { Rectangle().fill(C.accent).frame(height: 2) }
                            }
                    }.buttonStyle(.plain).accessibilityAddTraits(f == m.filter ? .isSelected : [])
                }
            }.padding(.horizontal, 20).padding(.top, 5)
            Divider()
            if m.locating { ProgressView("正在定位原文…").controlSize(.small).padding(10) }
            let sections = groups
            if sections.isEmpty {
                Spacer()
                EmptyMessage(icon: m.filter == .issues ? "checkmark" : "highlighter",
                             title: m.filter == .issues ? "没有待核对的批注" : (m.filter == .page ? "本页尚无批注" : "还没有批注"),
                             detail: m.filter == .all ? "选中原文后点「手动批注」，也可以导入 AI 返回的 JSON。" : "")
                if m.filter == .all {
                    PanelButton(text: "导入批注", icon: "square.and.arrow.down") { m.sheet = .importNotes }
                        .frame(maxWidth: .infinity)
                }
                Spacer()
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                Text(section.page.map { "第 \($0) 页" } ?? "页码待定")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(C.gray)
                                    .padding(.leading, 20).padding(.top, 19).padding(.bottom, 5)
                                ForEach(section.notes) { note in
                                    MarginNote(m: m, note: note).id(note.id)
                                    Divider().padding(.horizontal, 20)
                                }
                            }
                        }.padding(.bottom, 14)
                    }.onChange(of: m.selected) { _, id in
                        if let id { DispatchQueue.main.async { scroll.scrollTo(id, anchor: .top) } }
                    }
                }
            }
        }.background(C.paper)
    }
}

private struct MarginNote: View {
    @ObservedObject var m: Workspace
    let note: Note
    private var active: Bool { m.selected == note.id }
    private var color: Color { Color(rgb: note.kind.mark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Button { m.focus(note.id) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Rectangle().fill(color).frame(width: 13, height: 4)
                        Text(note.kind.label)
                        if note.isManual { Text("· 手动") }
                        Spacer()
                        if active { Image(systemName: "arrow.up.left").font(.system(size: 10)) }
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(C.gray)
                    if !active || MathMarkup.parts(in: note.quote).isEmpty {
                        Text(note.quote).font(.custom("Charter", size: 15)).lineSpacing(3)
                            .lineLimit(active ? nil : 2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("定位到原文并查看批注")
            if active {
                if !MathMarkup.parts(in: note.quote).isEmpty { MathPassage(text: note.quote, size: 15, quote: true) }
                if !note.translation.isEmpty { passage("译文", note.translation) }
                if !note.note.isEmpty { passage("注解", note.note) }
                if note.isManual {
                    Button("编辑批注") { m.editManualNote(note) }.buttonStyle(.link).font(.caption)
                }
            } else if !note.commentary.isEmpty {
                Button { m.focus(note.id) } label: {
                    Text(note.translation.isEmpty ? note.note : note.translation).font(.system(size: 12))
                        .lineSpacing(3).lineLimit(2).foregroundStyle(C.gray).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
            if active { OriginalPassage(m: m, note: note) }
            if let issue = m.anchors[note.id]?.issue {
                Label(issue, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(C.accent)
            }
        }.padding(.horizontal, 20).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? color.opacity(0.09) : .clear)
            .overlay(alignment: .leading) { if active { Rectangle().fill(color).frame(width: 3) } }
            .contextMenu {
                if note.isManual { Button("编辑手动批注…") { m.editManualNote(note) }; Divider() }
                Button("复制原文") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(note.quote, forType: .string) }
                Button("复制译文和注解") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(note.commentary, forType: .string) }.disabled(note.commentary.isEmpty)
            }
    }
    private func passage(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(C.gray)
            MathPassage(text: text)
        }
    }
}
