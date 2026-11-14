// Development-only render of real SwiftUI views with isolated sample data.
// This is not a screenshot of desktop interactions or a live market check.
import AppKit
import SwiftUI
import UserNotifications
import StockCore

struct PreviewQuotes: QuoteProviding {
    let values: [String: Quote]
    func fetch(_ symbols: [StockSymbol]) async throws -> [String: Quote] { values }
}

struct PreviewHistory: IntradayProviding {
    let root: URL
    func fetch(_ symbol: StockSymbol, mode: IntradayMode) async throws -> IntradaySeries {
        let label: String
        switch symbol.rawValue {
        case "sh600519": label = "stock"
        case "sz159915": label = "etf"
        default: throw IntradayHistoryError.unavailable
        }
        let data = try Data(contentsOf: root.appendingPathComponent("docs/fixtures/intraday-20261113-\(label)-\(mode == .line ? "minute" : "m5").json"))
        return try mode == .line ? IntradayParser.minutes(data, symbol: symbol) : IntradayParser.candles(data, symbol: symbol)
    }
}

actor DelayedPreviewHistory: IntradayProviding {
    enum Response: Hashable { case data, empty, failure }
    let base: PreviewHistory
    private var response = Response.data
    private var deliveries: [Response: Int] = [:]
    init(base: PreviewHistory) { self.base = base }
    func setResponse(_ response: Response) { self.response = response }
    func deliveryCount(_ response: Response) -> Int { deliveries[response, default: 0] }
    func fetch(_ symbol: StockSymbol, mode: IntradayMode) async throws -> IntradaySeries {
        let response = response
        try await Task.sleep(nanoseconds: 100_000_000)
        deliveries[response, default: 0] += 1
        if response == .failure { throw IntradayHistoryError.unavailable }
        let series = try await base.fetch(symbol, mode: mode)
        if response == .empty { return IntradaySeries(symbol: symbol, day: series.day, previousClose: series.previousClose, quote: series.quote) }
        return series
    }
}

@MainActor final class PreviewNotifications: NotificationSending {
    func status() async -> UNAuthorizationStatus { .denied }
    func requestPermission() async throws -> Bool { false }
    func send(identifier: String, title: String, body: String) async throws {}
}

@MainActor final class PreviewShortcutBackend: ShortcutRegistering {
    final class Token: ShortcutRegistration { func cancel() {} }
    func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws -> any ShortcutRegistration { Token() }
}

@MainActor final class PreviewBarkKeys: BarkKeyStoring {
    func read(allowInteraction: Bool) throws -> String? { "preview-key" }
    func write(_ key: String?) throws {}
}

@MainActor final class PreviewBarkSender: BarkSending {
    func send(configuration: BarkConfiguration, key: String, message: BarkMessage) async throws {}
}

@main struct PreviewRenderer {
    @MainActor static func main() async throws {
        // Process-local only: reproduce the user's always-visible scrollbar setting.
        UserDefaults.standard.setVolatileDomain(["AppleShowScrollBars": "Always"], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let history = PreviewHistory(root: project)
        let checkSwitching = ProcessInfo.processInfo.environment["TICKFIN_CHECK_SWITCHING"] == "1"
        // Default QA checks native layout without accumulating verification images.
        // Images can be emitted in memory, or explicitly saved for documentation.
        let saveImages = ProcessInfo.processInfo.environment["TICKFIN_PREVIEW_IMAGES"] == "1"
        let emitImages = Set((ProcessInfo.processInfo.environment["TICKFIN_PREVIEW_EMIT"] ?? "").split(separator: ",").map(String.init))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("StockBar-render-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: data) }
        let stamp = ISO8601DateFormatter().date(from: "2026-10-29T06:30:00Z")!
        let rows: [(String, String, String, String, String, Int, String)] = [
            ("600519", "贵州茅台", "1335", "1318.49", "1.25", 100, "1290"),
            ("000001", "平安银行", "11.20", "11.30", "-0.88", 2000, "11.65"),
            ("159915", "创业板ETF", "2.651", "2.702", "-1.89", 1000, "2.50")
        ]
        var state = SavedState()
        var quotes: [String: Quote] = [:]
        for (code, name, last, previous, percent, quantity, cost) in rows {
            let symbol = try StockSymbol(code)
            state.items.append(WatchItem(symbol: symbol, name: name, holding: Holding(quantity: quantity, averageCost: Decimal(string: cost)!)))
            quotes[symbol.rawValue] = Quote(symbol: symbol, name: name, last: Decimal(string: last)!, previousClose: Decimal(string: previous)!, percent: Decimal(string: percent)!, timestamp: stamp, dayHigh: Decimal(string: last)! * Decimal(string: "1.01")!, dayLow: Decimal(string: last)! * Decimal(string: "0.99")!)
        }
        state.assignMissingAliases()
        state.pinnedSymbol = state.items[0].id
        state.items[0].rule.upEnabled = true
        state.items[2].rule.price.belowEnabled = true
        state.items[2].rule.price.below = Decimal(string: "2.60")!
        state.items[2].rule.delivery = .bark
        state.bark.enabled = true
        state.menuMode = .stockPrice
        state.globalShortcut = GlobalShortcut(keyCode: 4, modifiers: [.command, .shift])
        state.previousStockShortcut = GlobalShortcut(keyCode: 123, modifiers: [.control, .option])
        state.nextStockShortcut = GlobalShortcut(keyCode: 124, modifiers: [.control, .option])
        try StateFile(url: data.appendingPathComponent("state.json")).save(state)
        let store = AppStore(dataDirectory: data, service: PreviewQuotes(values: quotes), notifications: PreviewNotifications(), shortcutBackend: PreviewShortcutBackend(), updateChecker: UpdateChecker(currentVersion: "1.2.3"), barkSender: PreviewBarkSender(), barkKeys: PreviewBarkKeys(), intradayService: history, clock: { stamp })
        await store.refresh()


        let testWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 280, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        testWindow.isReleasedWhenClosed = false
        let shared = NSHostingView(rootView: AnyView(PanelView(store: store).environment(\.colorScheme, .light)))
        testWindow.contentView = shared
        func render(_ name: String, store: AppStore, dark: Bool = false, reuse: NSHostingView<AnyView>? = nil) async throws -> NSSize {
            let view = reuse ?? NSHostingView(rootView: AnyView(PanelView(store: store).environment(\.colorScheme, dark ? .dark : .light)))
            if view === shared {
                view.rootView = AnyView(PanelView(store: store).environment(\.colorScheme, dark ? .dark : .light))
            }
            testWindow.contentView = view
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for _ in 0..<8 {
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            let size = view.fittingSize
            precondition(abs(size.width - 280) < 1 && (reuse != nil && reuse !== shared || size.height <= store.panelHeightLimit + 1), "Panel exceeds available space")
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            if saveImages || emitImages.contains(name) {
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                if saveImages { try png.write(to: output.appendingPathComponent(name + ".png")) }
                if emitImages.contains(name) { print("TICKFIN_IMAGE:\(name):\(png.base64EncodedString())") }
            }
            print("\(name): \(Int(size.width)) × \(Int(size.height)); content \(Int(store.panelContentHeight))")
            return size
        }
        _ = try await render("watchlist", store: store, reuse: shared)
        store.showHoldings = true
        _ = try await render("holdings-hidden", store: store, reuse: shared)
        store.revealed = true
        _ = try await render("holdings-dark", store: store, dark: true, reuse: shared)
        store.route = .edit(state.items[2].id, true)
        _ = try await render("price-alerts", store: store, reuse: shared)
        store.resetPrivacy()
        store.route = .settings
        // Render the full index independently so an offscreen route transition cannot retain
        // the preceding editor's viewport height in the documentation image.
        let settings = NSHostingView(rootView: AnyView(SettingsView(store: store)
            .frame(width: 280).background(UI.background)))
        _ = try await render("settings-index", store: store, reuse: settings)
        store.route = .settingsPage(.appearance)
        let menu = NSHostingView(rootView: AnyView(ScrollView(.vertical, showsIndicators: false) {
            SettingsView(store: store, section: .appearance).fixedSize(horizontal: false, vertical: true)
        }.frame(width: 280, height: 420).background(UI.background)))
        _ = try await render("menu-settings", store: store, reuse: menu)
        store.refreshBarkStatus()
        let bark = NSHostingView(rootView: AnyView(BarkSettingsView(store: store)
            .font(.system(size: 11)).controlSize(.small).padding(12).frame(width: 280).background(UI.background)))
        _ = try await render("bark-settings", store: store, reuse: bark)

        // Captured public market history plus fictional holdings; no personal data.
        var chartQuotes: [String: Quote] = [:]
        for (label, symbol) in [("stock", "sh600519"), ("etf", "sz159915")] {
            let raw = try Data(contentsOf: project.appendingPathComponent("docs/fixtures/intraday-20261113-\(label)-minute.json"))
            let root = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
            let payload = (root["data"] as! [String: Any])[symbol] as! [String: Any]
            let fields = (payload["qt"] as! [String: Any])[symbol] as! [String]
            chartQuotes.merge(QuoteParser.parse("v_\(symbol)=\"\(fields.joined(separator: "~"))\";")) { _, new in new }
        }
        var chartState = SavedState(items: chartQuotes.values.sorted { $0.symbol.rawValue < $1.symbol.rawValue }.map {
            WatchItem(symbol: $0.symbol, name: $0.name, holding: Holding(quantity: 100, averageCost: $0.previousClose))
        })
        chartState.items[0].rule.price.aboveEnabled = true
        chartState.items[0].rule.price.above = 1_430
        chartState.items[0].rule.price.belowEnabled = true
        chartState.items[0].rule.price.below = 1_390
        chartState.items[1].rule.upEnabled = true
        chartState.items[1].rule.downEnabled = true
        let chartDirectory = data.appendingPathComponent("charts")
        try StateFile(url: chartDirectory.appendingPathComponent("state.json")).save(chartState)
        let chartNow = ISO8601DateFormatter().date(from: "2026-11-14T02:00:00Z")!
        // Reproduce an older live cache alongside newer chart history. The chart
        // header must use its own date and values rather than this stale quote.
        let olderChartQuotes = chartQuotes.mapValues { value in
            var quote = value
            quote.timestamp = ISO8601DateFormatter().date(from: "2026-11-10T01:30:00Z")!
            quote.last *= Decimal(string: "0.9")!; quote.previousClose *= Decimal(string: "0.9")!
            quote.dayHigh = quote.dayHigh.map { $0 * Decimal(string: "0.9")! }
            quote.dayLow = quote.dayLow.map { $0 * Decimal(string: "0.9")! }
            return quote
        }
        let switchingHistory = DelayedPreviewHistory(base: history)
        let chartHistory: any IntradayProviding = checkSwitching ? switchingHistory : history
        let chartStore = AppStore(dataDirectory: chartDirectory, service: PreviewQuotes(values: olderChartQuotes), notifications: PreviewNotifications(),
            shortcutBackend: PreviewShortcutBackend(), barkSender: PreviewBarkSender(), barkKeys: PreviewBarkKeys(), intradayService: chartHistory, clock: { chartNow })
        await chartStore.refresh(manually: true)
        chartStore.route = .edit(chartState.items[0].id, false)
        _ = try await render("intraday-panel-hidden", store: chartStore, reuse: shared)
        if checkSwitching {
            func detailPicker(_ view: NSView) -> NSSegmentedControl? {
                if let control = view as? NSSegmentedControl, control.segmentCount == 4,
                   control.label(forSegment: 0) == "分时", control.label(forSegment: 1) == "5 分钟 K" { return control }
                return view.subviews.lazy.compactMap { detailPicker($0) }.first
            }
            struct Sample { let tab: String; let height: CGFloat; let top: CGFloat; let left: CGFloat; let pickerWidth: CGFloat; let pickerHeight: CGFloat }
            var samples: [Sample] = []
            func sample(_ tab: String) async throws {
                for _ in 0..<22 {
                    shared.frame = NSRect(origin: .zero, size: shared.fittingSize)
                    shared.layoutSubtreeIfNeeded()
                    guard let picker = detailPicker(shared) else { throw CocoaError(.coderValueNotFound) }
                    let rect = picker.convert(picker.bounds, to: shared)
                    samples.append(Sample(tab: tab, height: shared.fittingSize.height,
                        top: shared.isFlipped ? rect.minY : shared.bounds.height - rect.maxY,
                        left: rect.minX, pickerWidth: rect.width, pickerHeight: rect.height))
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            let sequence = ProcessInfo.processInfo.environment["TICKFIN_SWITCH_SEQUENCE"].map { $0.split(separator: ",").compactMap { Int($0) } }
                ?? [1, 0, 2, 3, 0, 1, 2, 0, 3, 1, 0]
            let scenarios: [(String, CGFloat, Bool, Bool, DelayedPreviewHistory.Response, Int)] = [
                ("hidden-light", 420, false, false, .data, 0),
                ("revealed-dark", 420, true, true, .data, 0),
                ("short-hidden", 180, false, false, .data, 0),
                ("short-revealed", 180, true, true, .data, 0),
                ("request-failure", 420, false, false, .failure, 1),
                ("empty-history", 420, false, false, .empty, 0)
            ]
            var checkedFrames = 0
            var emittedTabs: Set<String> = []
            for (name, limit, revealed, dark, response, itemIndex) in scenarios {
                await switchingHistory.setResponse(response)
                chartStore.panelHeightLimit = limit; chartStore.revealed = revealed
                chartStore.route = .edit(chartState.items[itemIndex].id, false)
                _ = try await render("switching-" + name, store: chartStore, dark: dark, reuse: shared)
                samples = []
                let initial = detailPicker(shared)?.selectedSegment ?? 0
                try await sample(detailPicker(shared)?.label(forSegment: initial) ?? "分时")
                for index in sequence {
                    guard let picker = detailPicker(shared), let action = picker.action else { throw CocoaError(.coderValueNotFound) }
                    let title = picker.label(forSegment: index) ?? String(index)
                    picker.selectedSegment = index
                    guard picker.sendAction(action, to: picker.target) else { throw CocoaError(.coderValueNotFound) }
                    try await sample(title)
                    precondition(detailPicker(shared)?.selectedSegment == index, "Tab action must change the actual picker selection")
                    let imageName = "switching-\(name)-tab-\(index)"
                    if (emitImages.contains(imageName) || saveImages), emittedTabs.insert(imageName).inserted {
                        _ = try await render(imageName, store: chartStore, dark: dark, reuse: shared)
                    }
                }
                let heightDrift = (samples.map(\.height).max() ?? 0) - (samples.map(\.height).min() ?? 0)
                let pickerDrift = (samples.map(\.top).max() ?? 0) - (samples.map(\.top).min() ?? 0)
                let pickerHeightDrift = (samples.map(\.pickerHeight).max() ?? 0) - (samples.map(\.pickerHeight).min() ?? 0)
                let leftDrift = (samples.map(\.left).max() ?? 0) - (samples.map(\.left).min() ?? 0)
                let widthDrift = (samples.map(\.pickerWidth).max() ?? 0) - (samples.map(\.pickerWidth).min() ?? 0)
                print("switching \(name): panel drift \(heightDrift)pt; picker top/left/width drift \(pickerDrift)/\(leftDrift)/\(widthDrift)pt; \(samples.count) frames")
                guard heightDrift < 1 && pickerDrift < 1 && pickerHeightDrift < 1 && leftDrift < 1 && widthDrift < 1,
                      samples.allSatisfy({ abs($0.height - chartStore.panelDisplayHeight) < 1 }),
                      samples.allSatisfy({ $0.height <= (revealed ? 370 : 350) }),
                      await switchingHistory.deliveryCount(response) > 0 else {
                    fputs("Layout changed during tab switching: \(name)\n", stderr)
                    exit(1)
                }
                checkedFrames += samples.count
            }
            print("Native tab switching: stable across \(checkedFrames) frames")
            return
        }
        precondition(chartStore.quotes == olderChartQuotes, "History must not replace the live quote cache")
        for mode in IntradayMode.allCases {
            let item = mode == .line ? chartState.items[0] : chartState.items[1]
            let model = IntradayChartModel(service: history, clock: { chartNow })
            await model.load(item.symbol, mode: mode)
            precondition(model.series?.isEmpty == false && model.error == nil, "Fixture history must load")
            for dark in [false, true] {
                chartStore.revealed = dark
                model.cursor = IntradayCursor()
                let chartView = NSHostingView(rootView: AnyView(StockEditor(store: chartStore, item: item, initialAlerts: false,
                    initialTab: mode == .line ? .line : .fiveMinute, chartModel: model)
                    .frame(width: 280).background(UI.background).environment(\.colorScheme, dark ? .dark : .light)))
                _ = try await render("intraday-\(mode.rawValue)-\(dark ? "dark" : "light")", store: chartStore, dark: dark, reuse: chartView)
                let series = model.series!
                model.cursor.selectedTimestamp = mode == .line ? series.points[60].timestamp : series.candles[12].timestamp
                _ = try await render("intraday-\(mode.rawValue)-selected-\(dark ? "dark" : "light")", store: chartStore, dark: dark, reuse: chartView)
            }
        }
        chartStore.revealed = false
        chartStore.panelHeightLimit = 180
        chartStore.route = .edit(chartState.items[1].id, false)
        _ = try await render("intraday-short-panel", store: chartStore, reuse: shared)
        let holding = NSHostingView(rootView: AnyView(StockEditor(store: chartStore, item: chartState.items[0], initialAlerts: false, initialTab: .holding)
            .frame(width: 280).background(UI.background)))
        _ = try await render("holding-editor-hidden", store: chartStore, reuse: holding)
        chartStore.panelHeightLimit = 420
        chartStore.route = .settingsPage(.data)
        _ = try await render("usage-settings", store: chartStore, reuse: shared)
        let guide = NSHostingView(rootView: AnyView(UsageGuideView(expandAll: true)
            .font(.system(size: 11)).controlSize(.small).padding(12).frame(width: 280).background(UI.background)))
        _ = try await render("usage-guide-expanded", store: chartStore, reuse: guide)
        chartStore.route = .settingsPage(.notifications)
        _ = try await render("notification-settings", store: chartStore, reuse: shared)
        print("Documentation previews rendered from real SwiftUI views with isolated sample data; no network pushes.")
    }
}
