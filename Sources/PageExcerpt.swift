import PDFKit
import SwiftUI

// Points use the PDF page's own coordinate system, the same one as PDFKit annotations.
struct PageRegion: Codable, Equatable {
    let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(_ rect: CGRect) {
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
    }
    var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

extension PDFPage {
    func excerpt(_ region: CGRect) -> NSImage? {
        guard let ref = pageRef else { return nil }
        let crop = ref.getBoxRect(.cropBox)
        let rotated = abs(ref.rotationAngle) % 180 == 90
        let display = CGRect(origin: .zero, size: rotated ? CGSize(width: crop.height, height: crop.width) : crop.size)
        let transform = ref.getDrawingTransform(.cropBox, rect: display, rotate: 0, preserveAspectRatio: true)
        let visible = region.applying(transform).intersection(display)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        let scale = min(5, 1050 / visible.width, 1400 / visible.height)
        guard let ctx = CGContext(data: nil, width: max(1, Int(ceil(visible.width * scale))), height: max(1, Int(ceil(visible.height * scale))),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -visible.minX, y: -visible.minY)
        ctx.concatenate(transform)
        ctx.drawPDFPage(ref)
        guard let image = ctx.makeImage() else { return nil }
        return NSImage(cgImage: image, size: visible.size)
    }
}

// Mounted only while the reader deliberately selects a visual anchor.
final class ExcerptPicker: NSView {
    weak var pdf: FolioPDFView?
    var commit: ((PDFPage, CGRect) -> Void)?
    var feedback: ((String) -> Void)?
    private var start: CGPoint?
    private var area: CGRect?
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        area = nil; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        area = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x-start.x), height: abs(end.y-start.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; area = nil; needsDisplay = true }
        guard let start, let pdf else { return }
        let a = pdf.convert(start, from: self), b = pdf.convert(event.locationInWindow, from: nil)
        guard abs(a.x-b.x) > 3, abs(a.y-b.y) > 3, let page = pdf.page(for: a, nearest: false),
              pdf.page(for: b, nearest: false) === page else { feedback?("请在同一页内拖出一个矩形。"); return }
        let first = pdf.convert(a, to: page), last = pdf.convert(b, to: page)
        let rect = CGRect(x: min(first.x,last.x), y: min(first.y,last.y), width: abs(last.x-first.x), height: abs(last.y-first.y))
        commit?(page, rect)
    }
    override func scrollWheel(with event: NSEvent) { pdf?.scrollViewForExcerpt?.scrollWheel(with: event) }
    override func draw(_ dirtyRect: NSRect) {
        guard let area else { return }
        NSColor.systemOrange.withAlphaComponent(0.16).setFill(); area.fill()
        NSColor.systemOrange.setStroke()
        let border = NSBezierPath(rect: area); border.lineWidth = 1.5; border.stroke()
    }
}
extension FolioPDFView {
    var scrollViewForExcerpt: NSScrollView? { documentView?.enclosingScrollView }
}
struct RegionSelection: NSViewRepresentable {
    @ObservedObject var m: Workspace
    func makeNSView(context: Context) -> ExcerptPicker {
        let view = ExcerptPicker()
        view.commit = { [weak m] page, rect in m?.attachRegion(page: page, rect: rect) }
        view.feedback = { [weak m] message in m?.notify(message) }
        return view
    }
    func updateNSView(_ view: ExcerptPicker, context: Context) { view.pdf = m.viewer }
}

struct OriginalPassage: View {
    @ObservedObject var m: Workspace
    let note: Note
    @State private var opened = false
    @State private var image: NSImage?
    private var anchor: Anchor? { m.anchors[note.id] }
    private var canPreview: Bool { anchor?.pageNumber != nil }
    private var isRegion: Bool { if case .area = anchor { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if canPreview && !isRegion {
                    Button(opened ? "收起原版" : "查看原版") { opened.toggle() }
                }
                Button(isRegion ? "重新框选" : "框选原版") { m.beginRegion(note) }
                    .help("在论文中框选原版图样，保留公式和特殊字形")
            }.buttonStyle(.link).font(.caption)
            if opened || isRegion {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("原版片段").help("来自原始 PDF 的页面片段")
                } else if canPreview {
                    Text("此处无法生成预览，可在左侧核对原页。").font(.caption).foregroundStyle(C.gray)
                }
            }
        }
        .onChange(of: opened) { _, _ in refresh() }
        .onChange(of: anchor) { _, _ in refresh() }
        .onAppear { refresh() }
    }
    private func refresh() {
        image = nil
        guard opened || isRegion, let p = anchor?.pageNumber, let page = m.document?.page(at: p-1) else { return }
        let box: CGRect
        switch anchor {
        case .area(_, let region): box = region
        case .found(let location):
            guard let selection = page.selection(for: location.range) else { return }
            box = selection.bounds(for: page).insetBy(dx: -3, dy: -3)
        default: return
        }
        image = page.excerpt(box)
    }
}
