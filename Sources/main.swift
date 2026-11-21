import AppKit
import SwiftUI
import PDFKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var model: Workspace?
    private var readingToolbar: ReadingToolbar?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            #if QA
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JIANDU_QA_ROOT"]!)
            #else
            let root = Library.defaultLocation()
            #endif
            let lib = try Library(root:root,assets:Bundle.main.resourceURL!)
            let m = Workspace(lib); model = m
            let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width:1400,height:900)
            let size = NSSize(width:min(1328,screen.width-20),height:min(840,screen.height-45))
            window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
            window.minSize = NSSize(width:900,height:560); window.title = "快读论文"
            window.backgroundColor = .windowBackgroundColor; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:Shell(m:m))
            readingToolbar = ReadingToolbar(window: window, model: m)
            window.center(); window.setFrameAutosaveName("JianDuMainWindow")
            installMenus()
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
            #if QA
            runInterfaceChecks(window:window,model:m)
            #endif
        } catch {
            let alert = NSAlert(); alert.messageText = "无法打开本地文献库"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    @objc func importPDF() { model?.choosePDF() }
    @objc func importNotes() { if model?.target != nil { model?.sheet = .importNotes } }
    @objc func manualNote() { model?.beginManualNote() }
    @objc func guide() { model?.sheet = .guide }
    func installMenus() {
        let bar = NSMenu()
        func menu(_ title:String)->NSMenu { let item = NSMenuItem(); bar.addItem(item); let menu = NSMenu(title:title); item.submenu = menu; return menu }
        let app = menu("快读论文")
        app.addItem(withTitle:"关于快读论文",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        app.addItem(.separator())
        app.addItem(withTitle:"退出快读论文",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let file = menu("文件")
        file.addItem(withTitle:"导入 PDF…",action:#selector(importPDF),keyEquivalent:"o").target = self
        let write = file.addItem(withTitle:"手动批注…",action:#selector(manualNote),keyEquivalent:"a")
        write.keyEquivalentModifierMask = [.command, .shift]; write.target = self
        file.addItem(withTitle:"导入 AI 批注…",action:#selector(importNotes),keyEquivalent:"i").target = self
        file.addItem(.separator()); file.addItem(withTitle:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        let edit = menu("编辑")
        for (name,sel,key) in [("撤销","undo:","z"),("重做","redo:","Z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] {
            edit.addItem(withTitle:name,action:Selector(sel),keyEquivalent:key)
        }
        let help = menu("帮助"); help.addItem(withTitle:"AI 批注指南",action:#selector(guide),keyEquivalent:"?").target = self
        NSApp.mainMenu = bar
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.regular); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
