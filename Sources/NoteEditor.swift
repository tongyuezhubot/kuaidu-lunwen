import SwiftUI

struct NoteEditor: View {
    @ObservedObject var m: Workspace
    let paperID: String
    let isNew: Bool
    let original: Note
    @State private var draft: Note
    @State private var pageText: String
    @State private var message = ""
    @State private var confirmingDelete = false
    @FocusState private var writing: Bool

    init(m: Workspace, paperID: String, isNew: Bool, original: Note) {
        self.m = m; self.paperID = paperID; self.isNew = isNew; self.original = original
        _draft = State(initialValue: original)
        _pageText = State(initialValue: original.page.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeading(title: isNew ? "手动批注" : (draft.isManual ? "编辑手动批注" : "编辑 AI 批注"),
                         subtitle: m.target?.title ?? "") { m.sheet = nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if draft.isManual {
                        manualExcerpt
                    } else {
                        HStack(spacing: 8) {
                            Text("原文引句").font(.headline)
                            Spacer()
                            Text("PDF 页码").font(.caption)
                            TextField("全文", text: $pageText).frame(width: 54).accessibilityLabel("PDF 页码")
                                .help("留空可在全文定位")
                        }
                        field($draft.quote, title: "原文引句", height: 60)
                        if original.region != nil {
                            Text("修改引文或页码后，将按文字重新定位框选区域。").font(.caption).foregroundStyle(C.gray)
                        }
                    }
                    HStack {
                        Text("高光类型").font(.headline)
                        Picker("高光类型", selection: $draft.kind) {
                            ForEach(Kind.allCases, id: \.self) { kind in Text(kind.label).tag(kind) }
                        }.labelsHidden().pickerStyle(.segmented)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(draft.isManual ? "注解（选填）" : "注解").font(.headline)
                        field($draft.note, title: "注解", height: 82).focused($writing)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(draft.isManual ? "译文（选填）" : "译文").font(.headline)
                        field($draft.translation, title: "译文", height: 72)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 10) {
                if !isNew {
                    Button("删除这条批注…", role: .destructive) { confirmingDelete = true }.buttonStyle(.link)
                }
                Spacer()
                Button("取消") { m.sheet = nil }.keyboardShortcut(.cancelAction)
                PanelButton(text: "保存批注", icon: "checkmark", prominent: true, action: save)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }.padding(22).frame(width: 550, height: draft.isManual ? 468 : 510)
            .foregroundStyle(C.ink).background(C.paper).tint(C.accent)
            .onAppear { writing = true }
            .alert(draft.isManual ? "删除这条手动批注？" : "删除这条 AI 批注？", isPresented: $confirmingDelete) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    do { try m.deleteNote(original, from: paperID) } catch { message = error.localizedDescription }
                }
            } message: { Text("这条批注的高光、译文和注解将从本篇文献中移除。") }
    }

    private var manualExcerpt: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(original.page.map { "原文 · 第 \($0) 页" } ?? "原文").font(.caption).foregroundStyle(C.gray)
            if let region = original.region, let n = original.page,
               let image = m.document?.page(at: n-1)?.excerpt(region.rect) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 72).accessibilityLabel("框选的原版片段")
            } else {
                Text(original.quote).font(.system(size: 14, design: .serif)).lineSpacing(4).textSelection(.enabled)
            }
        }.padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { Rectangle().fill(Color(rgb: draft.kind.mark)).frame(width: 3) }
    }
    private func save() {
        if !draft.isManual {
            let text = pageText.trimmed
            if !text.isEmpty && Int(text) == nil { message = "页码请输入整数，或留空以搜索全文。"; return }
            draft.page = Int(text)
        }
        do { try m.saveNote(draft, replacing: isNew ? nil : original, in: paperID) }
        catch { message = error.localizedDescription }
    }
    private func field(_ value: Binding<String>, title: String, height: CGFloat) -> some View {
        TextEditor(text: value).font(.system(size: 13)).scrollContentBackground(.hidden)
            .padding(5).frame(height: height).background(C.field)
            .overlay(Rectangle().stroke(C.line)).accessibilityLabel(title)
    }
}
