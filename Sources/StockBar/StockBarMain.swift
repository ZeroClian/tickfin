import AppKit
import Combine
import SwiftUI
import StockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let instanceLock = AppInstanceLock()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var store: AppStore!
    private var titleSubscription: AnyCancellable?
    private var panelObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var keyboardMonitor: Any?
    private lazy var normalIcon = makeStatusIcon(unread: false)
    private lazy var unreadIcon = makeStatusIcon(unread: true)
    private lazy var brandMark: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        for name in ["MenuBarTemplate", "MenuBarTemplate@2x"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let data = try? Data(contentsOf: url),
               let representation = NSBitmapImageRep(data: data) {
                representation.size = image.size
                image.addRepresentation(representation)
            }
        }
        // The unbundled SwiftPM executable has no app resources.
        return image.representations.isEmpty
            ? NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)!
            : image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = AppEditMenu.make()
        let args = CommandLine.arguments
        let customDirectory: URL?
        if let flag = args.firstIndex(of: "--data-dir"), flag + 1 < args.count {
            customDirectory = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        } else { customDirectory = nil }
        let directory = customDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StockBar")
        do {
            guard try instanceLock.acquire(directory: directory) else {
                if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "local.stockbar.app")
                    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }), let url = other.bundleURL {
                    NSWorkspace.shared.open(url)
                }
                NSApp.terminate(nil); return
            }
        } catch { NSApp.terminate(nil); return }
        store = AppStore(dataDirectory: customDirectory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self; button.action = #selector(togglePanel)
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("打开 Tickfin")
            button.toolTip = "Tickfin"
        }
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(rootView: PanelView(store: store))
        popover.contentViewController = host
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, NSApp.isActive,
                  let window = self.popover.contentViewController?.view.window,
                  NSApp.keyWindow === window, window.attachedSheet == nil,
                  NSApp.modalWindow == nil else { return event }
            let responder = window.firstResponder
            let editingText = responder is NSTextView || responder is NSTextField
            return self.store.handlePanelKey(event, editingText: editingText) ? nil : event
        }
        titleSubscription = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle(); self?.resizePanel() }
        }
        panelObserver = NotificationCenter.default.addObserver(forName: .openStockPanel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showPanel() }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: .closeStockPanel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }
        store.onShortcutToggle = { [weak self] in self?.togglePanel() }
        updateTitle()
        store.start()
        if store.storageHealthy { UpdateTransaction.acknowledgeLaunch(arguments: args) }
        if args.contains("--show-panel") { showPanel() }
    }

    private func updateTitle() {
        statusItem.button?.title = store.menuTitle
        let unread = store.hasUnreadAlerts
        statusItem.button?.image = unread ? unreadIcon : normalIcon
        statusItem.button?.toolTip = unread ? "Tickfin · 有提醒" : "Tickfin"
        statusItem.button?.setAccessibilityLabel(unread ? "Tickfin，有未读提醒" : "打开 Tickfin")
    }
    private func makeStatusIcon(unread: Bool) -> NSImage {
        let mark = brandMark
        let image = NSImage(size: NSSize(width: unread ? 22 : 16, height: 16), flipped: false) { _ in
            mark.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
            if unread { NSColor.black.setFill(); NSBezierPath(ovalIn: NSRect(x: 18, y: 10, width: 3, height: 3)).fill() }
            return true
        }
        image.isTemplate = true
        return image
    }
    private func resizePanel() {
        guard popover != nil else { return }
        let target = NSSize(width: 280, height: store.panelDisplayHeight)
        if popover.contentSize != target { popover.contentSize = target }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.updateChecker.updater.shouldTerminate() == false ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        store?.stop()
    }
    func popoverDidClose(_ notification: Notification) { store.resetPrivacy() }
    func applicationDidResignActive(_ notification: Notification) {
        if popover?.isShown == true { store.resetPrivacy(); popover.performClose(nil) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if popover != nil { showPanel() }
        return false
    }
    @objc private func togglePanel() {
        if popover.isShown { store.resetPrivacy(); popover.performClose(nil) } else { showPanel() }
    }
    private func showPanel() {
        guard let button = statusItem.button else { return }
        store.resetPrivacy()
        store.synchronizeClock()
        store.panelHeightLimit = min(420, max(120, (button.window?.screen?.visibleFrame.height ?? 600) - 40))
        resizePanel()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await store.updatePermission() }
    }
}

@main
struct StockBarEntry {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--apply-update"), index + 1 < CommandLine.arguments.count {
            do { try UpdateTransaction.apply(planURL: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { exit(1) }
        }
        // Read-only history check: does not start the app, load holdings or notify.
        if CommandLine.arguments.contains("--check-history") {
            Task {
                do {
                    for code in ["600519", "510300", "159915"] {
                        let symbol = try StockSymbol(code)
                        for mode in IntradayMode.allCases {
                            let series = try await IntradayService().fetch(symbol, mode: mode)
                            guard !series.isEmpty else { throw IntradayHistoryError.unavailable }
                            let count = mode == .line ? series.points.count : series.candles.count
                            print("\(symbol.rawValue) \(mode.title) \(MarketClock.day(series.day)) \(count) 条 截至 \(UI.time(series.lastTimestamp!))")
                        }
                    }
                    exit(0)
                } catch { fputs("走势检查失败：\(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run()
            return
        }
// Read-only diagnostic entry point: no notifications, settings, or holdings are created.
if CommandLine.arguments.contains("--check-market") {
    Task {
        do {
            let symbols = try ["600519", "000001", "300750", "301269", "688981", "920002",
                               "510300", "159915", "588000", "513100", "518880", "511010", "511990",
                               "520900", "530060", "551000", "563300"].map { try StockSymbol($0) }
            let quotes = try await QuoteService().fetch(symbols)
            for symbol in symbols {
                guard let q = quotes[symbol.rawValue] else { throw QuoteServiceError.empty }
                print("\(q.symbol.rawValue) \(q.name) 涨跌 \(q.change) 涨跌幅 \(q.percent)% 时间 \(UI.time(q.timestamp, full: true))")
            }
            exit(0)
        } catch { fputs("行情检查失败：\(error.localizedDescription)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}

    }
}
