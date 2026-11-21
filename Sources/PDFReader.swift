import SwiftUI
import PDFKit

final class FolioPDFView: PDFView {
    var picked: ((String) -> Void)?
    private var clickMonitor: Any?
    private var clickStart: (id: String, point: CGPoint)?
    private weak var filteredDocument: NSView?
    private var appliedNight: Bool?
    func applyPageAppearance(night: Bool) {
        guard let surface = documentView, surface !== filteredDocument || appliedNight != night else { return }
        filteredDocument = surface
        appliedNight = night
        if night, let filter = CIFilter(name: "CIColorMatrix") {
            // Reverse the brightness of the page while retaining the hue of ink and highlights.
            let diagonal: CGFloat = 0.16, other: CGFloat = -0.49
            filter.setValue(CIVector(x: diagonal, y: other, z: other, w: 0), forKey: "inputRVector")
            filter.setValue(CIVector(x: other, y: diagonal, z: other, w: 0), forKey: "inputGVector")
            filter.setValue(CIVector(x: other, y: other, z: diagonal, w: 0), forKey: "inputBVector")
            filter.setValue(CIVector(x: 0.88, y: 0.88, z: 0.88, w: 0), forKey: "inputBiasVector")
            surface.wantsLayer = true
            surface.layer?.rasterizationScale = window?.backingScaleFactor ?? 2
            if let tone = CIFilter(name: "CIColorPolynomial") {
                let curve = CIVector(x: 0.009, y: 0.02, z: 0.21, w: 0.80)
                for channel in ["inputRedCoefficients", "inputGreenCoefficients", "inputBlueCoefficients"] {
                    tone.setValue(curve, forKey: channel)
                }
                surface.contentFilters = [filter, tone]
            } else { surface.contentFilters = [filter] }
        } else { surface.contentFilters = [] }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if appliedNight == true { filteredDocument?.layer?.rasterizationScale = window?.backingScaleFactor ?? 2 }
    }
    var pickingRegion = false
    var fitWidth = true
    var lastWidth: CGFloat = 0
    var pageObserver: NSObjectProtocol?
    var scaleObserver: NSObjectProtocol?
    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        for token in [pageObserver, scaleObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) }
    }
    func fit() {
        guard bounds.width > 70, let page = currentPage ?? document?.page(at: 0) else { return }
        let b = page.bounds(for: displayBox)
        let width = page.rotation % 180 == 0 ? b.width : b.height
        guard width > 0 else { return }
        fitWidth = true; lastWidth = bounds.width
        let scale = max(minScaleFactor, min(maxScaleFactor,(bounds.width-48)/width))
        if abs(scaleFactor-scale) > 0.002 { scaleFactor = scale }
    }
    override func layout() {
        super.layout()
        if fitWidth && abs(lastWidth - bounds.width) > 1 { fit() }
    }
    func zoom(_ multiple: CGFloat) {
        fitWidth = false
        scaleFactor = max(minScaleFactor, min(maxScaleFactor, scaleFactor * multiple))
    }
    private func noteID(at point: CGPoint) -> String? {
        guard let page = page(for: point, nearest: false) else { return nil }
        let local = convert(point, to: page)
        let key = PDFAnnotationKey(rawValue: "/JianduID")
        for mark in page.annotations.reversed() where mark.bounds.contains(local) {
            if let id = mark.value(forAnnotationKey: key) as? String { return id }
        }
        return nil
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        clickStart = nil
        guard window != nil else { return }
        // PDFKit's page and annotation subviews can receive events instead of PDFView.
        // Observe this window's clicks without consuming its native text-selection events.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.followHighlightClick(event)
            return event
        }
    }
    private func followHighlightClick(_ event: NSEvent) {
        guard !pickingRegion else { clickStart = nil; return }
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseDown {
            clickStart = nil
            guard bounds.contains(point), !isHiddenOrHasHiddenAncestor, event.clickCount == 1,
                  event.modifierFlags.intersection([.shift, .option, .control]).isEmpty,
                  let id = noteID(at: point) else { return }
            clickStart = (id, point)
            return
        }
        guard let start = clickStart else { return }
        if hypot(point.x-start.point.x, point.y-start.point.y) > 3 {
            clickStart = nil
        } else if event.type == .leftMouseUp {
            clickStart = nil
            if noteID(at: point) == start.id { picked?(start.id) }
        }
    }
}
struct ReaderCanvas: NSViewRepresentable {
    @Environment(\.colorScheme) var scheme
    @ObservedObject var m: Workspace
    func makeNSView(context: Context) -> FolioPDFView {
        let view = FolioPDFView()
        view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.backgroundColor = C.canvas
        view.displayBox = .cropBox; view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 17, left: 12, bottom: 13, right: 12)
        view.autoScales = false; view.minScaleFactor = 0.15; view.maxScaleFactor = 5
        view.picked = { [weak m] id in m?.focus(id, fromPDF: true) }
        view.pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak m, weak view] _ in
            DispatchQueue.main.async {
                guard let view, let m, m.viewer === view, let doc = view.document, let pg = view.currentPage else { return }
                let n = doc.index(for: pg) + 1; if m.page != n { m.page = n }
            }
        }
        view.scaleObserver = NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak m, weak view] _ in
            DispatchQueue.main.async {
                guard let view, let m, m.viewer === view else { return }
                let pct = Int((view.scaleFactor * 100).rounded()); if m.scaling != pct { m.scaling = pct }
            }
        }
        m.viewer = view
        return view
    }
    func updateNSView(_ view: FolioPDFView, context: Context) {
        view.pickingRegion = m.selectingRegion != nil
        if view.document !== m.document {
            view.document = m.document; view.fit()
            if let pg = m.document?.page(at: 0) { view.go(to: pg) }
            DispatchQueue.main.async { [weak view] in view?.fit() }
        }
        view.applyPageAppearance(night: scheme == .dark && !m.originalPageColors)
    }
}
