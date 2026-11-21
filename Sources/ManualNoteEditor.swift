import SwiftUI

struct ManualNoteEditor: View {
    @ObservedObject var m: Workspace
    let paperID: String
    let isNew: Bool
    @State var draft: Note
    @State private var message = ""
    @State private var confirmingDelete = false
    @FocusState private var writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            SheetHeading(title: isNew ? "手动批注" : "编辑手动批注",
                         subtitle: "\(m.target?.title ?? "") · 第 \(draft.page.map(String.init) ?? "？") 页") { m.sheet = nil }
            ScrollView {
                if let region = draft.region, let pageNumber = draft.page,
                   let page = m.document?.page(at: pageNumber-1), let img = page.excerpt(region.rect) {
                    Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 72)
                        .accessibilityLabel("框选的原版片段")
                } else {
                    Text(draft.quote).font(.system(size: 14, design: .serif)).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12).padding(.trailing, 2).textSelection(.enabled)
                }
            }.frame(height: 72).overlay(alignment: .leading) { Rectangle().fill(Color(rgb: draft.kind.mark)).frame(width: 3) }
            HStack {
                Text("高光类型").font(.system(size: 12, weight: .semibold))
                Picker("高光类型", selection: $draft.kind) {
                    ForEach(Kind.allCases, id: \.self) { kind in Text(kind.label).tag(kind) }
                }.labelsHidden().pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("注解（选填）").font(.system(size: 12, weight: .semibold))
                field($draft.note, title: "注解").focused($writing)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("译文（选填）").font(.system(size: 12, weight: .semibold))
                field($draft.translation, title: "译文")
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 10) {
                if !isNew {
                    Button("删除批注…", role: .destructive) { confirmingDelete = true }.buttonStyle(.link)
                }
                Spacer()
                Button("取消") { m.sheet = nil }.keyboardShortcut(.cancelAction)
                PanelButton(text: "保存批注", icon: "checkmark", prominent: true) {
                    draft.note = draft.note.trimmed
                    draft.translation = draft.translation.trimmed
                    do { try m.saveManualNote(draft, to: paperID) } catch { message = error.localizedDescription }
                }.keyboardShortcut(.return, modifiers: [.command])
            }
        }.padding(23).frame(width: 545, height: 468)
            .foregroundStyle(C.ink).background(C.paper).tint(C.accent)
            .onAppear { writing = true }
            .alert("删除这条手动批注？", isPresented: $confirmingDelete) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    do { try m.deleteManualNote(draft, from: paperID) } catch { message = error.localizedDescription }
                }
            } message: { Text("这条批注的高光、译文和注解将从文献库中移除。") }
    }

    private func field(_ value: Binding<String>, title: String) -> some View {
        TextEditor(text: value).font(.system(size: 13)).scrollContentBackground(.hidden)
            .padding(6).background(C.field)
            .overlay(Rectangle().stroke(C.line))
            .accessibilityLabel(title)
    }
}
