import Foundation
import PDFKit

struct Location: Equatable {
    let page: Int
    let range: NSRange
}
extension Note {
    static func fromSelection(_ selection: PDFSelection?, in document: PDFDocument) throws -> Note {
        guard let selection, let page = selection.pages.first else {
            throw Problem("请先拖选一段文字。公式或扫描页可用工具栏「更多」中的「框选并批注」。")
        }
        guard selection.pages.count == 1 else { throw Problem("选区跨越了页码，请按页分开添加批注。") }
        guard page.document === document, let text = page.string as NSString? else { throw Problem("当前选区没有可读取的文字。") }
        let count = selection.numberOfTextRanges(on: page)
        let ranges = (0..<count).map { selection.range(at: $0, on: page) }.sorted { $0.location < $1.location }
        guard let first = ranges.first else { throw Problem("请先选中一段原文。") }
        var end = first.location
        for range in ranges {
            guard range.location <= text.length, range.length <= text.length - range.location else { throw Problem("请重新选择 PDF 中的文字。") }
            if range.location > end, !text.substring(with: NSRange(location: end, length: range.location-end)).trimmed.isEmpty {
                throw Problem("请为每段不连续的选区分别添加批注。")
            }
            end = max(end, NSMaxRange(range))
        }
        let range = NSRange(location: first.location, length: end-first.location)
        let quote = text.substring(with: range).trimmed
        guard !quote.isEmpty else { throw Problem("选区只有空白，请选中要批注的文字。") }
        let exact = text.range(of: quote, options: .literal, range: range)
        let before = text.substring(to: exact.location).suffix(48)
        let after = text.substring(from: NSMaxRange(exact)).prefix(48)
        return Note(manualQuote: quote, page: document.index(for: page)+1, offset: exact.location, prefix: String(before), suffix: String(after))
    }
}
enum Anchor: Equatable {
    case found(Location), area(Int, CGRect), missing, ambiguous, invalidPage, noText, invalidRegion
    var pageNumber: Int? {
        switch self {
        case .found(let spot): return spot.page
        case .area(let page, _): return page
        default: return nil
        }
    }
    var issue: String? {
        switch self {
        case .found, .area: return nil
        case .missing: return "未找到原文，请核对引文与页码。"
        case .ambiguous: return "引文有多个匹配，可补充前后文或页码。"
        case .invalidPage: return "页码超出这篇文献的范围。"
        case .noText: return "这页没有可搜索的文字，可以直接框选原版。"
        case .invalidRegion: return "原版区域超出页面，请重新框选。"
        }
    }
}

// Keep original UTF-16 offsets so normalized matches select the actual PDF text.
struct SearchText {
    let value: NSString
    let offsets: [NSRange]
    init(_ text: String, ignoringCase: Bool = false) {
        let src = text as NSString
        var output = ""
        var map: [NSRange] = []
        var i = 0
        var previousCJK = false
        func cjk(_ s: String) -> Bool { s.unicodeScalars.first.map { (0x2e80...0x9fff).contains($0.value) || (0xac00...0xd7af).contains($0.value) || (0x20000...0x323af).contains($0.value) } ?? false }
        while i < src.length {
            let r = src.rangeOfComposedCharacterSequence(at: i)
            let raw = src.substring(with: r)
            i = NSMaxRange(r)
            if raw == "\u{ad}" || raw == "\u{200b}" { continue }
            if raw == "-" && i < src.length {
                var end = i
                while end < src.length, [9, 32].contains(src.character(at: end)) { end += 1 }
                if end < src.length, [10,13].contains(src.character(at: end)) {
                    while end < src.length, [9,10,13,32].contains(src.character(at: end)) { end += 1 }
                    if end < src.length { i = end; continue }
                }
            }
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var end = i
                while end < src.length, let ch = UnicodeScalar(src.character(at: end)), CharacterSet.whitespacesAndNewlines.contains(ch) { end += 1 }
                let nextCJK = end < src.length && cjk(src.substring(with: src.rangeOfComposedCharacterSequence(at: end)))
                i = end
                if previousCJK && nextCJK { continue }
                output.append(" "); map.append(NSRange(location: r.location, length: end-r.location))
                continue
            }
            // Fold printing ligatures and full-width ASCII, but preserve superscripts,
            // subscripts, Greek case and math alphabets such as ℝ or 𝑥.
            let scalar = raw.unicodeScalars.first!.value
            let typography = (0xfb00...0xfb06).contains(scalar) || (0xff01...0xff5e).contains(scalar)
                ? raw.precomposedStringWithCompatibilityMapping : raw.precomposedStringWithCanonicalMapping
            let normalized = (ignoringCase ? typography.lowercased() : typography)
                .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
                .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            output += normalized
            map.append(contentsOf: repeatElement(r, count: normalized.utf16.count))
            previousCJK = cjk(raw)
        }
        value = output as NSString; offsets = map
    }
    func matches(_ quote: NSString, prefix: String, suffix: String, limit: Int) -> [NSRange] {
        guard quote.length > 0 else { return [] }
        var start = 0, out: [NSRange] = []
        while start < value.length {
            let hit = value.range(of: quote as String, options: .literal, range: NSRange(location: start, length: value.length-start))
            if hit.location == NSNotFound { break }
            let end = NSMaxRange(hit)
            let beforeOK = prefix.isEmpty || value.substring(to: hit.location).trimmed.hasSuffix(prefix)
            let afterOK = suffix.isEmpty || value.substring(from: end).trimmed.hasPrefix(suffix)
            if beforeOK && afterOK {
                let a = offsets[hit.location], b = offsets[end-1]
                out.append(NSRange(location: a.location, length: NSMaxRange(b)-a.location))
                if out.count >= limit { break }
            }
            start = hit.location + 1
        }
        return out
    }
}
final class AnchorIndex {
    let document: PDFDocument
    var cache: [Int: SearchText] = [:]
    private var folded: [Int: SearchText] = [:]
    init(_ doc: PDFDocument) { document = doc }
    func find(_ note: Note) -> Anchor {
        let count = document.pageCount
        if let p = note.page, !(1...max(1,count)).contains(p) { return .invalidPage }
        if let region = note.region, let p = note.page {
            guard let page = document.page(at: p-1), page.bounds(for: .cropBox).insetBy(dx: -0.1, dy: -0.1).contains(region.rect)
            else { return .invalidRegion }
            return .area(p, region.rect)
        }
        if let page = note.page, let start = note.text_offset, start >= 0,
           let raw = document.page(at: page-1)?.string as NSString?,
           start <= raw.length, note.quote.utf16.count <= raw.length - start {
            let range = NSRange(location: start, length: note.quote.utf16.count)
            if raw.substring(with: range) == note.quote { return .found(Location(page: page, range: range)) }
        }
        let pages = note.page.map { [$0] } ?? Array(1...max(1,count))
        // A private font code or replacement glyph is not a reliable search anchor.
        if note.quote.unicodeScalars.contains(where: { $0.value == 0xfffd || $0.properties.generalCategory == .privateUse }) { return .missing }
        let exact = search(note, pages: pages, ignoringCase: false)
        guard exact == .missing, note.quote.split(whereSeparator: { $0.isWhitespace }).count >= 3,
              note.quote.range(of: #"^[A-Za-z\s.,:;!?'’“”"–—-]+$"#, options: .regularExpression) != nil
        else { return exact }
        return search(note, pages: pages, ignoringCase: true)
    }
    private func search(_ note: Note, pages: [Int], ignoringCase: Bool) -> Anchor {
        let query = SearchText(note.quote, ignoringCase: ignoringCase).value
        let pre = SearchText(note.prefix ?? "", ignoringCase: ignoringCase).value as String
        let post = SearchText(note.suffix ?? "", ignoringCase: ignoringCase).value as String
        var found: Location?
        var hasText = false
        for p in pages {
            if Task.isCancelled { return .missing }
            let pageText: SearchText
            if let cached = ignoringCase ? folded[p] : cache[p] { pageText = cached }
            else {
                pageText = SearchText(document.page(at: p-1)?.string ?? "", ignoringCase: ignoringCase)
                if ignoringCase { folded[p] = pageText } else { cache[p] = pageText }
            }
            if pageText.value.length > 0 { hasText = true }
            for range in pageText.matches(query, prefix: pre.trimmed, suffix: post.trimmed, limit: 2) {
                if found != nil { return .ambiguous }
                found = Location(page: p, range: range)
            }
        }
        if let found { return .found(found) }
        return hasText ? .missing : .noText
    }
}
