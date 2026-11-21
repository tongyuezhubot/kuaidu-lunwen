import SwiftUI
import PDFKit
import UniformTypeIdentifiers

private actor PaperCovers {
    static let shared = PaperCovers()
    private let cache = NSCache<NSURL, NSData>()
    private init() { cache.countLimit = 128 }
    func cover(_ url: URL) -> Data? {
        if let data = cache.object(forKey: url as NSURL) { return data as Data }
        guard !Task.isCancelled, let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        let image = page.thumbnail(of: NSSize(width: 100, height: 138), for: .cropBox)
        guard let data = image.tiffRepresentation else { return nil }
        cache.setObject(data as NSData, forKey: url as NSURL)
        return data
    }
}

private struct PaperCover: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .shadow(color: .black.opacity(0.19), radius: 1.4, y: 1)
            } else { Image(systemName: "doc").font(.title2).foregroundStyle(C.gray) }
        }.frame(width: 39, height: 51).accessibilityHidden(true)
            .task(id: url) {
                let result = await PaperCovers.shared.cover(url)
                if !Task.isCancelled { image = result.flatMap(NSImage.init(data:)) }
            }
    }
}

struct CollectionView: View {
    @ObservedObject var m: Workspace
    private var results: [Paper] {
        m.papers.filter { (m.surface != .starred || $0.starred) && (m.query.trimmed.isEmpty || [$0.title,$0.author,$0.filename].contains { $0.localizedCaseInsensitiveContains(m.query.trimmed) }) }
    }
    var body: some View {
        let papers = results
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(papers.count) 篇文献").font(.system(size: 13, weight: .medium))
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(C.gray)
                    TextField("搜索标题、作者或文件名", text: $m.query).textFieldStyle(.plain)
                    if !m.query.isEmpty { ToolIcon(icon: "xmark.circle.fill", label: "清除搜索") { m.query = "" } }
                }.font(.system(size: 12)).padding(.horizontal, 8).frame(width: 216, height: 28)
                    .background(C.side, in: RoundedRectangle(cornerRadius: 5))
            }.padding(.vertical, 20)
            HStack(spacing: 16) {
                Text("文献").frame(maxWidth: .infinity, alignment: .leading)
                Text("页数").frame(width: 46, alignment: .trailing)
                Text("批注").frame(width: 46, alignment: .trailing)
                Color.clear.frame(width: 24, height: 1)
            }.font(.caption).foregroundStyle(C.gray).padding(.bottom, 8)
            Divider()
            if papers.isEmpty {
                Spacer()
                EmptyMessage(icon: "books.vertical", title: m.query.isEmpty ? "这里还没有文献" : "没有找到匹配的文献",
                             detail: m.query.isEmpty ? (m.surface == .starred ? "为文献添加星标后，可在这里查看。" : "导入一篇 PDF，开始阅读与批注。") : "试试其他标题、作者或文件名。")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(papers) { p in
                            HStack(spacing: 16) {
                                Button { m.open(p.id) } label: {
                                    HStack(spacing: 16) {
                                        PaperCover(url: m.library.url(p.id))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(p.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                                            Text(p.sample ? "示例文献" : (p.author.isEmpty ? p.filename : p.author))
                                                .font(.callout).foregroundStyle(C.gray).lineLimit(1)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        Text("\(p.pages)").frame(width: 46, alignment: .trailing)
                                        Text("\(p.notes.count)").frame(width: 46, alignment: .trailing)
                                    }.font(.system(size: 12)).monospacedDigit().padding(.vertical, 11).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("打开《\(p.title)》")
                                ToolIcon(icon: p.starred ? "star.fill" : "star", label: p.starred ? "取消星标" : "添加星标") { m.star(p.id) }
                                    .foregroundStyle(p.starred ? C.accent : C.gray)
                            }.contextMenu {
                                Button("打开文献") { m.open(p.id) }
                                Button("从文献库移除…") { m.remove(p) }
                            }
                            Divider()
                        }
                    }
                }
            }
        }.padding(.horizontal, 27).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(C.paper)
    }
}

struct SheetHeading: View {
    let title: String, subtitle: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(C.gray).lineLimit(2)
            }
            Spacer()
            ToolIcon(icon: "xmark", label: "关闭", action: dismiss)
        }
    }
}

struct PromptPicker: View {
    @Binding var selection: AnnotationPrompt
    var body: some View {
        Picker("阅读目的", selection: $selection) {
            ForEach(AnnotationPrompt.choices) { item in Text(item.title).tag(item) }
        }
    }
}

struct Guide: View {
    @ObservedObject var m: Workspace
    @State private var copied = false
    @State private var saveError = ""
    @State private var fullPrompt = false
    func saveResource(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else { saveError = "找不到格式文件。"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = name + ".json"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do { try Data(contentsOf: url).write(to: dest, options: .atomic) } catch { saveError = error.localizedDescription }
    }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "AI 批注指南", subtitle: "选好阅读目的，把提示词和 PDF 交给 AI，再导入返回的 JSON。") { m.sheet = nil }
                .padding(20)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(AnnotationPrompt.choices) { template in
                        Button { m.promptTemplate = template } label: {
                            Text(template.title).font(.system(size: 13, weight: m.promptTemplate == template ? .semibold : .regular))
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading).frame(height: 32)
                                .background(m.promptTemplate == template ? C.selection : .clear, in: RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(template == m.promptTemplate ? .isSelected : [])
                    }
                    Spacer()
                }.padding(9).frame(width: 117).background(C.side)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(m.promptTemplate.title).font(.custom("Songti SC Bold", size: 22))
                    if let p = m.target { Text("用于《\(p.title)》").font(.callout).foregroundStyle(C.gray).lineLimit(2) }
                    ScrollView {
                        Text(fullPrompt ? m.prompt : m.promptTemplate.instructions)
                            .font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.id(m.promptTemplate.id + String(fullPrompt))
                    Toggle("显示完整提示词与 JSON 格式", isOn: $fullPrompt).font(.callout)
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            if !saveError.isEmpty { Text(saveError).foregroundStyle(.red).font(.caption) }
            HStack {
                Menu("保存格式文件") {
                    Button("示例批注 JSON…") { saveResource("sample") }
                    Button("JSON Schema…") { saveResource("annotation-schema") }
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                PanelButton(text: copied ? "已复制提示词" : "复制提示词", icon: copied ? "checkmark" : "doc.on.doc", prominent: true) { copied = m.copyPrompt() }
            }.padding(.horizontal, 20).frame(height: 52)
        }.frame(width: 630, height: 445).foregroundStyle(C.ink).background(C.paper).tint(C.accent)
            .onChange(of: m.promptTemplate.id) { _, _ in copied = false }
    }
}

struct ImportNotes: View {
    @ObservedObject var m: Workspace
    @State private var input = ""
    @State private var issue = ""
    @State private var copied = false
    func accept(_ data: Data) {
        do { try m.importJSON(data) } catch { issue = error.localizedDescription }
    }
    func chooseFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { accept(try Data(contentsOf: url)) } catch { issue = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeading(title: "导入批注", subtitle: m.target?.title ?? "") { m.sheet = nil }
            Divider()
            HStack {
                Text("批注文件").font(.headline)
                Spacer()
                PanelButton(text: "选择 JSON 文件…", icon: "folder", action: chooseFile)
            }
            Text("或粘贴 JSON").font(.headline)
            TextEditor(text: $input).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(7).background(C.field).overlay(Rectangle().stroke(C.line))
                .accessibilityLabel("批注 JSON")
            if !issue.isEmpty { Text(issue).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                PromptPicker(selection: $m.promptTemplate).pickerStyle(.menu).fixedSize()
                Button(copied ? "已复制提示词" : "复制提示词") { copied = m.copyPrompt() }.buttonStyle(.link)
                Spacer()
                PanelButton(text: "导入粘贴内容", icon: "square.and.arrow.down", prominent: true) { accept(Data(input.utf8)) }
                    .disabled(input.trimmed.isEmpty)
            }
        }.padding(21).frame(width: 560, height: 402).foregroundStyle(C.ink).background(C.paper).tint(C.accent)
            .onChange(of: m.promptTemplate.id) { _, _ in copied = false }
    }
}
