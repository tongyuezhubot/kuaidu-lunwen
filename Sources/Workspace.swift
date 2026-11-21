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
    case guide, importNotes, manual(paperID: String, note: Note, isNew: Bool)
    var id: String {
        switch self {
        case .guide: return "guide"
        case .importNotes: return "import"
        case .manual(_, let note, _): return "manual-" + note.id
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
        selectingRegion = nil; anchors = [:]; selected = nil; page = 1; filter = .all; locating = false
        guard let p = target else { document = nil; return }
        let url = library.url(p.id)
        guard let doc = PDFDocument(url: url) else {
            document = nil; error = "无法读取文献库中的 PDF 副本。可以重新导入原文件来恢复阅读。"; return
        }
        document = doc; selected = p.notes.first?.id
        guard !p.notes.isEmpty else { return }
        locating = true
        let ticket = generation
        let task = Task.detached(priority: .userInitiated) { () -> [String: Anchor] in
            guard let copy = PDFDocument(url: url) else { return [:] }
            let index = AnchorIndex(copy)
            var locations: [String: Anchor] = [:]
            for n in p.notes {
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
            for n in p.notes where currentNotes[n.id] == n && installed[n.id] == nil {
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
        }
        viewer?.annotationsChanged(on: page)
        return anchor
    }

    func beginManualNote() {
        guard surface == .reader, sheet == nil, let id = current, let doc = document else { return }
        do {
            let note = try Note.fromSelection(viewer?.currentSelection, in: doc)
            sheet = .manual(paperID: id, note: note, isNew: true)
        } catch { self.error = error.localizedDescription }
    }

    func editManualNote(_ note: Note) {
        guard note.isManual, let current else { return }
        sheet = .manual(paperID: current, note: note, isNew: false)
    }

    private func removeHighlight(_ id: String, in doc: PDFDocument) {
        guard let n = anchors[id]?.pageNumber, let page = doc.page(at: n-1) else { return }
        for mark in page.annotations where mark.value(forAnnotationKey: PDFAnnotationKey(rawValue:"/JianduID")) as? String == id {
            page.removeAnnotation(mark)
        }
        viewer?.annotationsChanged(on: page)
    }

    func saveManualNote(_ note: Note, to paperID: String) throws {
        guard current == paperID, note.isManual, let doc = document else { throw Problem("原文献已经关闭，请重新打开后保存。") }
        let anchor = anchors[note.id] ?? AnchorIndex(doc).find(note)
        try library.merge([note], into: paperID)
        removeHighlight(note.id, in: doc)
        anchors[note.id] = drawHighlight(note, anchor: anchor, in: doc)
        refresh()
        viewer?.clearSelection()
        showNotes = true; filter = .all; selected = note.id; sheet = nil
        notify("已保存手动批注")
    }

    func deleteManualNote(_ note: Note, from paperID: String) throws {
        guard current == paperID, note.isManual, let doc = document else { throw Problem("原文献已经关闭。") }
        try library.edit(paperID) { $0.notes.removeAll { $0.id == note.id && $0.isManual } }
        removeHighlight(note.id, in: doc); anchors.removeValue(forKey: note.id)
        refresh()
        if selected == note.id { selected = nil }
        sheet = nil; notify("已删除手动批注")
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
            sheet = .manual(paperID: paper.id, note: draft, isNew: true)
            return
        }
        guard case .existing(let id) = picking, var note = paper.notes.first(where: { $0.id == id }) else { return }
        note.page = pageNumber; note.region = PageRegion(box); note.text_offset = nil
        do {
            try library.merge([note], into: paper.id)
            removeHighlight(id, in: doc)
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
