import SwiftUI
import PDFKit
import UniformTypeIdentifiers

enum ReadingAppearance: String, CaseIterable {
    case night = "夜间", day = "浅色", system = "跟随系统"
    var native: NSAppearance? {
        switch self {
        case .night: return NSAppearance(named: .darkAqua)
        case .day: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }
}
enum Surface { case reader, all, starred }
enum RegionTarget: Equatable { case existing(String), new }
enum Sheet: Identifiable {
    case guide, importNotes, editor(paperID: String, note: Note, isNew: Bool)
    var id: String {
        switch self {
        case .guide: return "guide"
        case .importNotes: return "import"
        case .editor(let paperID, let note, _): return paperID + "/" + note.id
        }
    }
}
enum Filter: String, CaseIterable { case all = "全部", page = "本页", issues = "待核对" }

extension NSColor {
    convenience init(rgb: Int) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 255)/255, green: CGFloat((rgb >> 8) & 255)/255, blue: CGFloat(rgb & 255)/255, alpha: 1)
    }
}
extension Color { init(rgb: Int) { self.init(nsColor: NSColor(rgb: rgb)) } }
enum C {
    static func adaptive(_ light: Int, _ dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(rgb: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }
    static let ink = Color(nsColor: .labelColor)
    static let gray = Color(nsColor: .secondaryLabelColor)
    static let line = Color(nsColor: adaptive(0xDCD9D2, 0x4B4945))
    static let accent = Color(nsColor: adaptive(0x925438, 0xE7AA82))
    static let paper = Color(nsColor: adaptive(0xFDFCF9, 0x292927))
    static let side = Color(nsColor: adaptive(0xF2F0EB, 0x242422))
    static let selection = Color(nsColor: adaptive(0xE4DED4, 0x413B34))
    static let field = Color(nsColor: .textBackgroundColor)
    static let canvas = adaptive(0xE4E2DD, 0x1D1D1C)
}
extension Kind {
    var hue: Int {
        switch self { case .claim: return 0xAC7D2C; case .method: return 0x497968; case .finding: return 0x4E78A0; case .limitation: return 0x9C6270 }
    }
    var mark: Int {
        switch self { case .claim: return 0xF4D27E; case .method: return 0xAAD8BB; case .finding: return 0xB0D4F0; case .limitation: return 0xF0BCCA }
    }
}
@MainActor final class Workspace: ObservableObject {
    @Published var appearance: ReadingAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "ReadingAppearance")
            NSApp.appearance = appearance.native
        }
    }
    @Published var originalPageColors = UserDefaults.standard.bool(forKey: "OriginalPageColors") {
        didSet { UserDefaults.standard.set(originalPageColors, forKey: "OriginalPageColors") }
    }
    let library: Library
    @Published var papers: [Paper] = []
    @Published var current: String?
    @Published var surface: Surface = .reader {
        didSet { if surface != .reader { selectingRegion = nil } }
    }
    @Published var selectingRegion: RegionTarget?
    @Published var promptTemplate = AnnotationPrompt.closeReading
    @Published var sheet: Sheet?
    @Published var error: String?
    @Published var toast = ""
    @Published var query = ""
    @Published var filter: Filter = .all
    @Published var document: PDFDocument?
    @Published var anchors: [String: Anchor] = [:]
    @Published var selected: String?
    @Published var page = 1
    @Published var scaling = 100
    @Published var locating = false
    @Published var showNotes = true
    @Published var showSidebar = true
    weak var viewer: FolioPDFView?
    private var highlights: [String: [PDFAnnotation]] = [:]
    private var worker: Task<[String: Anchor], Never>?
    private var generation = UUID()
    private var toastTask: Task<Void,Never>?
    var target: Paper? { papers.first { $0.id == current } }
    var unresolved: Int { anchors.values.filter { $0.issue != nil }.count }
    init(_ lib: Library) {
        appearance = UserDefaults.standard.string(forKey: "ReadingAppearance").flatMap(ReadingAppearance.init(rawValue:)) ?? .night
        library = lib
        NSApp?.appearance = appearance.native
        refresh()
        current = lib.catalog.current ?? papers.first?.id
        if current == nil { surface = .all } else { loadReader() }
    }
    func refresh() { papers = library.catalog.papers.sorted { $0.opened > $1.opened } }
    func notify(_ message: String) {
        toastTask?.cancel(); toast = message
        toastTask = Task { try? await Task.sleep(nanoseconds: 3_400_000_000); if !Task.isCancelled { toast = "" } }
    }
    func open(_ id: String) {
        do {
            try library.select(id); refresh(); current = id; surface = .reader
            loadReader()
        } catch { self.error = error.localizedDescription }
    }
    func loadReader() {
        worker?.cancel(); generation = UUID()
        highlights.removeAll(); selectingRegion = nil; anchors = [:]; selected = nil; page = 1; filter = .all; locating = false
        guard let p = target else { document = nil; return }
        let url = library.url(p.id)
        guard let doc = PDFDocument(url: url) else {
            document = nil; error = "无法读取文献库中的 PDF 副本。可以重新导入原文件来恢复阅读。"; return
        }
        document = doc; selected = p.notes.first?.id
        locatePendingNotes(in: doc, paper: p)
    }

    private func locatePendingNotes(in doc: PDFDocument, paper: Paper) {
        worker?.cancel(); generation = UUID()
        let pending = paper.notes.filter { anchors[$0.id] == nil }
        locating = !pending.isEmpty
        guard locating else { return }
        let url = library.url(paper.id)
        let ticket = generation
        let task = Task.detached(priority: .userInitiated) { () -> [String: Anchor] in
            guard let copy = PDFDocument(url: url) else { return [:] }
            let index = AnchorIndex(copy)
            var locations: [String: Anchor] = [:]
            for n in pending {
                if Task.isCancelled { break }
                locations[n.id] = index.find(n)
            }
            return locations
        }
        worker = task
        Task { [weak self] in
            let result = await task.value
            guard let self, self.generation == ticket else { return }
            // A reader may add, edit or delete a note while the original batch is locating.
            let currentNotes = Dictionary(uniqueKeysWithValues: (self.target?.notes ?? []).map { ($0.id, $0) })
            var installed = self.anchors
            for n in pending where currentNotes[n.id] == n && installed[n.id] == nil {
                installed[n.id] = self.drawHighlight(n, anchor: result[n.id] ?? .missing, in: doc)
            }
            self.anchors = installed; self.locating = false
        }
    }

    private func drawHighlight(_ note: Note, anchor: Anchor, in doc: PDFDocument) -> Anchor {
        guard let n = anchor.pageNumber, let page = doc.page(at: n-1) else { return anchor }
        let rects: [CGRect]
        switch anchor {
        case .found(let spot):
            guard let selection = page.selection(for: spot.range) else { return .missing }
            rects = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        case .area(_, let rect): rects = [rect]
        default: return anchor
        }
        guard !rects.isEmpty else { return .missing }
        for rect in rects {
            let mark = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            mark.color = NSColor(rgb: note.kind.mark)
            mark.contents = note.commentary
            mark.userName = "快读论文"
            mark.setValue(note.id, forAnnotationKey: PDFAnnotationKey(rawValue: "/JianduID"))
            page.addAnnotation(mark)
            highlights[note.id, default: []].append(mark)
        }
        viewer?.annotationsChanged(on: page)
        return anchor
    }

    func beginManualNote() {
        guard surface == .reader, sheet == nil, let id = current, let doc = document else { return }
        do {
            let note = try Note.fromSelection(viewer?.currentSelection, in: doc)
            sheet = .editor(paperID: id, note: note, isNew: true)
        } catch { self.error = error.localizedDescription }
    }

    func editNote(_ note: Note) {
        guard let paper = target, paper.notes.contains(note) else { return }
        sheet = .editor(paperID: paper.id, note: note, isNew: false)
    }

    private func removeHighlights(for ids: Set<String>) {
        var pages = Set<PDFPage>()
        for id in ids {
            for mark in highlights.removeValue(forKey: id) ?? [] {
                guard let page = mark.page else { continue }
                page.removeAnnotation(mark)
                pages.insert(page)
            }
            anchors.removeValue(forKey: id)
        }
        for page in pages { viewer?.annotationsChanged(on: page) }
    }

    func saveNote(_ draft: Note, replacing original: Note?, in paperID: String) throws {
        guard current == paperID, let paper = target, let doc = document else { throw Problem("原文献已经关闭，请重新打开后保存。") }
        let existing = paper.notes.firstIndex { $0.id == draft.id }
        guard existing.map({ paper.notes[$0] }) == original,
              original.map({ $0.source == draft.source }) ?? draft.isManual else {
            throw Problem("这条批注已被修改或删除，请关闭编辑窗口后重新打开。")
        }
        var note = draft
        note.quote = draft.quote.trimmed; note.translation = draft.translation.trimmed; note.note = draft.note.trimmed
        guard !note.quote.isEmpty else { throw Problem("请填写要定位的引文。") }
        guard note.isManual || (!note.translation.isEmpty && !note.note.isEmpty) else { throw Problem("请填写 AI 批注的译文和注解。") }
        if note.hasUnexpectedControlCharacters { throw Problem("批注含有异常控制字符，请检查粘贴的文字或公式。") }
        let moved = original.map { $0.quote != note.quote || $0.page != note.page } ?? false
        if moved {
            if let page = note.page, !(1...max(1, doc.pageCount)).contains(page) { throw Problem("请填写这篇 PDF 的实际页码，或留空以搜索全文。") }
            note.region = nil; note.text_offset = nil; note.prefix = nil; note.suffix = nil
        }
        try library.edit(paperID) { p in
            if let existing { p.notes[existing] = note } else { p.notes.append(note) }
        }
        let knownAnchor = moved ? nil : anchors[note.id]
        removeHighlights(for: [note.id])
        refresh()
        if let anchor = knownAnchor {
            anchors[note.id] = drawHighlight(note, anchor: anchor, in: doc)
        } else if note.isManual {
            anchors[note.id] = drawHighlight(note, anchor: AnchorIndex(doc).find(note), in: doc)
        } else if let updated = target {
            locatePendingNotes(in: doc, paper: updated)
        }
        viewer?.clearSelection()
        showNotes = true; filter = .all; selected = note.id; sheet = nil
        notify("已保存批注")
    }

    func deleteNote(_ note: Note, from paperID: String) throws {
        guard current == paperID, target?.notes.contains(note) == true else {
            throw Problem("文献或批注已更改，请关闭编辑窗口后重新打开。")
        }
        try removeNotes([note.id], from: paperID)
        sheet = nil
        notify("已删除批注")
    }

    func confirmClearAINotes(in paper: Paper) {
        let count = paper.notes.filter { !$0.isManual }.count
        guard count > 0, current == paper.id else { return }
        let alert = NSAlert()
        alert.messageText = "清除《\(paper.title)》的 AI 批注？"
        alert.informativeText = "将移除本篇全部 \(count) 条 AI 批注和对应高光。手动批注会保留。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清除 \(count) 条 AI 批注").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try clearAINotes(in: paper.id) } catch { self.error = error.localizedDescription }
    }

    func clearAINotes(in paperID: String) throws {
        guard let paper = target, paper.id == paperID else { throw Problem("当前文献已更改，请重新选择。") }
        let ids = Set(paper.notes.filter { !$0.isManual }.map(\.id))
        guard !ids.isEmpty else { return }
        try removeNotes(ids, from: paperID)
        notify("已清除 \(ids.count) 条 AI 批注")
    }

    private func removeNotes(_ ids: Set<String>, from paperID: String) throws {
        try library.edit(paperID) { $0.notes.removeAll { ids.contains($0.id) } }
        removeHighlights(for: ids)
        refresh()
        if let selected, ids.contains(selected) { self.selected = target?.notes.first?.id }
        if case .existing(let id) = selectingRegion, ids.contains(id) { selectingRegion = nil }
        if locating, let doc = document, let paper = target { locatePendingNotes(in: doc, paper: paper) }
    }
    func choosePDF() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        panel.prompt = "导入文献"; panel.title = "选择论文 PDF"
        if panel.runModal() == .OK { importPDFs(panel.urls) }
    }
    func importPDFs(_ urls: [URL]) {
        var last: String?, added = 0, existing = 0, errors: [String] = []
        for url in urls {
            do {
                let count = library.catalog.papers.count
                last = try library.addPDF(url)
                if library.catalog.papers.count > count { added += 1 } else { existing += 1 }
            } catch { errors.append(error.localizedDescription) }
        }
        refresh()
        if let last { current = last; surface = .reader; loadReader(); notify(added == 0 ? "已打开文献库中的 PDF" : "已导入 \(added) 篇文献" + (existing > 0 ? "，\(existing) 篇已在库中" : "")) }
        if !errors.isEmpty { error = errors.joined(separator: "\n") }
    }
    @discardableResult func importJSON(_ data: Data) throws -> Int {
        guard let p = target else { throw Problem("请先打开要批注的 PDF。") }
        let result = try Envelope.parse(data, expectedHash: p.id)
        guard !result.annotations.isEmpty else { throw Problem("annotations 为空。请至少添加一条批注。") }
        let oldIDs = Set(p.notes.map(\.id))
        let updates = result.annotations.filter { oldIDs.contains($0.id) }.count
        try library.merge(result.annotations, into: p.id)
        refresh(); surface = .reader; showNotes = true; loadReader()
        selected = result.annotations.first?.id; sheet = nil
        notify("已新增 \(result.annotations.count-updates) 条，更新 \(updates) 条批注")
        return result.annotations.count
    }
    func star(_ id: String) {
        do { try library.edit(id) { $0.starred.toggle() }; refresh() } catch { self.error = error.localizedDescription }
    }
    func remove(_ p: Paper) {
        let alert = NSAlert(); alert.messageText = "从文献库移除《\(p.title)》？"
        alert.informativeText = "将移除库内的 PDF 副本及 \(p.notes.count) 条批注。导入前的原文件会保留。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try library.remove(p.id); refresh()
            if current == p.id { current = library.catalog.current; surface = .all; loadReader() }
            notify("已移除文献")
        } catch { self.error = error.localizedDescription }
    }
    func focus(_ id: String, fromPDF: Bool = false) {
        guard target?.notes.contains(where: { $0.id == id }) == true else { return }
        if selectingRegion != .existing(id) { selectingRegion = nil }
        selected = id; showNotes = true
        if fromPDF { filter = .all; return }
        if case .found(let loc) = anchors[id], let page = document?.page(at: loc.page-1), let sel = page.selection(for: loc.range) {
            viewer?.go(to: sel)
        } else if case .area(let p, let rect) = anchors[id], let page = document?.page(at: p-1) {
            viewer?.go(to: rect, on: page)
        } else if let page = target?.notes.first(where: { $0.id == id })?.page { goto(page) }
    }
    func beginRegion(_ note: Note) {
        guard document != nil else { return }
        focus(note.id)
        selectingRegion = .existing(note.id)
    }
    func attachRegion(page: PDFPage, rect: CGRect) {
        guard let picking = selectingRegion, let doc = document, page.document === doc, let paper = target else { return }
        let box = rect.intersection(page.bounds(for: .cropBox))
        guard !box.isEmpty, !box.isNull else { return }
        let pageNumber = doc.index(for: page) + 1
        if picking == .new {
            var draft = Note(manualQuote: "原版片段", page: pageNumber, offset: 0, prefix: "", suffix: "")
            draft.region = PageRegion(box); draft.text_offset = nil
            selectingRegion = nil
            sheet = .editor(paperID: paper.id, note: draft, isNew: true)
            return
        }
        guard case .existing(let id) = picking, var note = paper.notes.first(where: { $0.id == id }) else { return }
        note.page = pageNumber; note.region = PageRegion(box); note.text_offset = nil
        do {
            try library.merge([note], into: paper.id)
            removeHighlights(for: [id])
            anchors[id] = drawHighlight(note, anchor: .area(pageNumber, box), in: doc)
            selectingRegion = nil; filter = .all; selected = id; refresh()
            notify("已保存原版片段")
        } catch { self.error = error.localizedDescription }
    }
    func goto(_ n: Int) {
        guard let p = document?.page(at: n-1) else { return }; viewer?.go(to: p)
    }
    func exportNotes(_ pdf: Bool) {
        guard let p = target else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [pdf ? .pdf : .json]
        panel.nameFieldStringValue = p.title.replacingOccurrences(of: "/", with: "－") + (pdf ? "（批注）.pdf" : ".json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if url.standardizedFileURL.resolvingSymlinksInPath() == library.url(p.id).standardizedFileURL.resolvingSymlinksInPath() { throw Problem("请选择新的导出位置，以保留库内原文。") }
            let data: Data
            if pdf {
                guard !locating, let annotated = document?.dataRepresentation() else { throw Problem("请等待批注定位完成，再导出 PDF。") }
                data = annotated
            } else { data = try Envelope(document_sha256: p.id, annotations: p.notes).encoded() }
            try data.write(to: url, options: .atomic)
            notify(pdf && unresolved > 0 ? "已导出 PDF；\(unresolved) 条待核对批注可另存为 JSON" : "已导出到 \(url.lastPathComponent)")
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func copyPrompt() -> Bool {
        let paste = NSPasteboard.general
        paste.clearContents()
        let copied = paste.setString(prompt, forType: .string)
        notify(copied ? "已复制「\(promptTemplate.title)」提示词" : "复制失败，可从批注指南中选取提示词")
        return copied
    }
    var prompt: String { promptTemplate.text(documentHash: target?.id) }
}
