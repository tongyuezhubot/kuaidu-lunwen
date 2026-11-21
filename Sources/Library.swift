import Foundation
import PDFKit
import CryptoKit
import Darwin

struct Problem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

enum Kind: String, Codable, CaseIterable {
    case claim, method, finding, limitation
    var label: String {
        switch self { case .claim: return "核心观点"; case .method: return "研究方法"; case .finding: return "研究发现"; case .limitation: return "局限性" }
    }
}
struct Note: Codable, Identifiable, Equatable {
    var id: String
    var page: Int?
    var kind: Kind
    var quote: String
    var translation: String
    var note: String
    var prefix: String?
    var suffix: String?
    var source: String?
    var text_offset: Int?
    var region: PageRegion?
    var isManual: Bool { source == "manual" }
    var commentary: String { [translation, note].filter { !$0.isEmpty }.joined(separator: "\n\n") }
    enum CodingKeys: String, CodingKey { case id, page, kind, quote, translation, note, prefix, suffix, source, text_offset, region }

    init(manualQuote: String, page: Int, offset: Int, prefix: String, suffix: String) {
        id = UUID().uuidString
        self.page = page
        kind = .claim
        quote = manualQuote
        translation = ""
        note = ""
        self.prefix = prefix.trimmed
        self.suffix = suffix.trimmed
        source = "manual"
        text_offset = offset
    }

    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        page = try v.decodeIfPresent(Int.self, forKey: .page)
        region = try v.decodeIfPresent(PageRegion.self, forKey: .region)
        if let region, !region.isValid || page == nil { throw Problem("区域批注需要有效的矩形与 PDF 页码。") }
        quote = try v.decode(String.self, forKey: .quote).trimmed
        source = try v.decodeIfPresent(String.self, forKey: .source)
        text_offset = try v.decodeIfPresent(Int.self, forKey: .text_offset)
        translation = try v.decode(String.self, forKey: .translation).trimmed
        note = try v.decode(String.self, forKey: .note).trimmed
        kind = try v.decodeIfPresent(Kind.self, forKey: .kind) ?? .claim
        prefix = try v.decodeIfPresent(String.self, forKey: .prefix)?.trimmed
        suffix = try v.decodeIfPresent(String.self, forKey: .suffix)?.trimmed
        id = try v.decodeIfPresent(String.self, forKey: .id)?.trimmed ?? String(digest(Data("\(page ?? 0)\n\(quote)\n\(prefix ?? "")\n\(suffix ?? "")".utf8)).prefix(24))
        guard !id.isEmpty, !quote.isEmpty, isManual || (!translation.isEmpty && !note.isEmpty) else { throw Problem("批注的 id、quote、translation 和 note 不能留空。") }
        if let text_offset, text_offset < 0 { throw Problem("text_offset 不能小于 0。") }
        if let page, page < 1 { throw Problem("page 应为从 1 开始的 PDF 页码。") }
    }
}
struct Envelope: Codable {
    var schema_version = 1
    var document_sha256: String?
    var annotations: [Note]
    static func parse(_ data: Data, expectedHash: String? = nil) throws -> Envelope {
        guard var s = String(data: data, encoding: .utf8)?.trimmed else { throw Problem("请使用 UTF-8 编码的 JSON 文件。") }
        if s.first == "\u{feff}" { s.removeFirst() }
        let fence = String(repeating: "\u{60}", count: 3)
        if s.hasPrefix(fence) && s.hasSuffix(fence), let firstLine = s.firstIndex(of: "\n") {
            let inside = String(s[s.index(after: firstLine)...])
            s = String(inside.dropLast(3)).trimmed
        }
        let payload = Data(s.utf8)
        struct Version: Decodable { let schema_version: Int }
        do {
            let decoder = JSONDecoder()
            guard try decoder.decode(Version.self, from: payload).schema_version == 1 else { throw Problem("此工具支持 schema_version 为 1 的批注。") }
            let result = try decoder.decode(Envelope.self, from: payload)
            if let hash = result.document_sha256, let expectedHash, hash.lowercased() != expectedHash { throw Problem("这份批注的文献指纹与当前 PDF 不符。请打开生成批注时使用的原始 PDF。") }
            for row in result.annotations {
                let hasBrokenEscape = [row.quote, row.translation, row.note].contains { text in
                    text.unicodeScalars.contains { $0.value < 32 && ![9, 10, 13].contains($0.value) }
                }
                if hasBrokenEscape { throw Problem("批注「\(row.id)」含有异常控制字符。请检查公式，在 JSON 中把一个反斜杠写成两个。") }
            }
            guard Set(result.annotations.map(\.id)).count == result.annotations.count else { throw Problem("同一份 JSON 里出现了重复的批注 id。请为每条批注使用独立的 id。") }
            return result
        } catch let e as DecodingError {
            var path = ""
            switch e {
            case .keyNotFound(let key, let c): path = (c.codingPath + [key]).map(\.stringValue).joined(separator: ".")
            case .valueNotFound(_, let c), .typeMismatch(_, let c), .dataCorrupted(let c): path = c.codingPath.map(\.stringValue).joined(separator: ".")
            @unknown default: break
            }
            if path.hasSuffix("kind") { throw Problem("\(path) 须为 claim、method、finding 或 limitation。") }
            throw Problem(path.isEmpty ? "未能读取 JSON。请检查括号、逗号和引号；公式里的反斜杠在 JSON 中要写成两个。" : "请检查 \(path) 的字段名称、类型和值。")
        }
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
struct Paper: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    let author: String
    let filename: String
    let pages: Int
    var starred: Bool
    var notes: [Note]
    let added: Date
    var opened: Date
    var sample: Bool
}
struct Catalog: Codable { var version = 1; var papers: [Paper]; var current: String? }
final class Library {
    let root: URL
    let manifest: URL
    let files: URL
    private var lockFD: Int32 = -1
    private(set) var catalog: Catalog
    static func defaultLocation() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JianDu", isDirectory: true)
    }
    init(root: URL, assets: URL) throws {
        self.root = root
        manifest = root.appendingPathComponent("library.json")
        files = root.appendingPathComponent("Papers", isDirectory: true)
        catalog = Catalog(papers: [], current: nil)
        let fm = FileManager.default
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        lockFD = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw Problem("文献库正被另一个窗口使用，或文件夹不可写。请关闭其他快读论文实例并检查文件夹权限。") }
        if fm.fileExists(atPath: manifest.path) {
            catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: manifest))
            guard catalog.version == 1, Set(catalog.papers.map(\.id)).count == catalog.papers.count,
                  catalog.papers.allSatisfy({ $0.id.count == 64 && $0.id.allSatisfy { $0.isHexDigit } }) else { throw Problem("文献库索引版本或数据有误。请检查 library.json。") }
        } else {
            let pdf = assets.appendingPathComponent("reading-in-layers.pdf")
            let hash = try addPDF(pdf, sample: true)
            let envelope = try Envelope.parse(Data(contentsOf: assets.appendingPathComponent("sample.json")), expectedHash: hash)
            try merge(envelope.annotations, into: hash)
        }
    }
    deinit { if lockFD >= 0 { close(lockFD) } }
    func url(_ id: String) -> URL { files.appendingPathComponent(id + ".pdf") }
    func save(_ next: Catalog) throws {
        let data = try JSONEncoder().encode(next)
        try data.write(to: manifest, options: .atomic)
        catalog = next
    }
    func edit(_ id: String, _ change: (inout Paper) -> Void) throws {
        var next = catalog
        guard let i = next.papers.firstIndex(where: { $0.id == id }) else { throw Problem("文献不存在。") }
        change(&next.papers[i]); try save(next)
    }
    func select(_ id: String) throws {
        var next = catalog
        guard let i = next.papers.firstIndex(where: { $0.id == id }) else { throw Problem("文献不存在。") }
        next.current = id; next.papers[i].opened = Date(); try save(next)
    }
    @discardableResult func addPDF(_ source: URL, sample: Bool = false) throws -> String {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let id = digest(data)
        if catalog.papers.contains(where: { $0.id == id }) {
            if !FileManager.default.fileExists(atPath: url(id).path) { try data.write(to: url(id), options: .atomic) }
            try select(id); return id
        }
        guard let doc = PDFDocument(data: data), !doc.isLocked, doc.pageCount > 0 else { throw Problem("无法打开 \(source.lastPathComponent)。请使用可读且已解锁的 PDF。") }
        let attrs = doc.documentAttributes ?? [:]
        let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?.trimmed ?? ""
        let now = Date()
        let item = Paper(id: id, title: sample ? "逐层阅读一篇论文" : (title.isEmpty ? source.deletingPathExtension().lastPathComponent : title), author: (attrs[PDFDocumentAttribute.authorAttribute] as? String)?.trimmed ?? "", filename: source.lastPathComponent, pages: doc.pageCount, starred: false, notes: [], added: now, opened: now, sample: sample)
        try data.write(to: url(id), options: .atomic)
        var next = catalog; next.papers.append(item); next.current = id
        do { try save(next) } catch { try? FileManager.default.removeItem(at: url(id)); throw error }
        return id
    }
    func merge(_ incoming: [Note], into id: String) throws {
        try edit(id) { paper in
            let byID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
            let prior = Set(paper.notes.map(\.id))
            paper.notes = paper.notes.map { prior in
                guard var next = byID[prior.id] else { return prior }
                if next.region == nil, let region = prior.region, next.quote == prior.quote,
                   next.page == nil || next.page == prior.page {
                    next.region = region
                    next.page = prior.page
                }
                return next
            } + incoming.filter { !prior.contains($0.id) }
        }
    }
    func remove(_ id: String) throws {
        var next = catalog; next.papers.removeAll { $0.id == id }
        if next.current == id { next.current = next.papers.sorted { $0.opened > $1.opened }.first?.id }
        try save(next)
        if FileManager.default.fileExists(atPath: url(id).path) { try FileManager.default.removeItem(at: url(id)) }
    }
}
