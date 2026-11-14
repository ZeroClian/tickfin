import AppKit
import Combine
import Foundation
import UserNotifications
import StockCore

enum PanelRoute: Hashable {
    case home, add, edit(String, Bool), settings, settingsPage(SettingsSection), details, inbox, sorting
}

enum SettingsSection: Hashable { case appearance, refresh, notifications, bark, updates, data }

/// Display-only policy. Alert eligibility remains governed by MarketClock.isFresh.
enum QuoteDisplayPolicy {
    static func isOld(_ quote: Quote, now: Date) -> Bool {
        guard MarketClock.day(quote.timestamp) == MarketClock.day(now), quote.timestamp <= now else { return true }
        if MarketClock.isTradingTime(now) { return !MarketClock.isFresh(quote, now: now) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard TradingSchedule.isTradingDay(now), let weekday = components.weekday, (2...6).contains(weekday),
              let hour = components.hour, let minute = components.minute else { return true }
        let minutes = hour * 60 + minute
        let close: Date?
        if minutes >= 15 * 60 {
            close = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: now)
        } else if minutes >= 11 * 60 + 30 && minutes < 13 * 60 {
            close = calendar.date(bySettingHour: 11, minute: 30, second: 0, of: now)
        } else { return true }
        guard let close else { return true }
        // Keep the original timestamp, including provider updates after the close.
        return quote.timestamp < close.addingTimeInterval(-180)
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var state = SavedState()
    @Published private(set) var quotes: [String: Quote] = [:]
    @Published private(set) var failedSymbols: Set<String> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAdding = false
    @Published private(set) var storageHealthy = true
    @Published private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var hasBarkKey = false
    @Published private(set) var now: Date
    @Published var route: PanelRoute = .home {
        didSet { if oldValue != route { navigationRevision &+= 1; isRecordingShortcut = false } }
    }
    @Published var isRecordingShortcut = false
    @Published var recordingShortcutAction: ShortcutAction = .togglePanel
    @Published private(set) var shortcutError: String?
    let updateChecker: UpdateChecker
    let shortcutManager: GlobalShortcutManager
    let previousShortcutManager: GlobalShortcutManager
    let nextShortcutManager: GlobalShortcutManager
    var onShortcutToggle: (() -> Void)?
    @Published var keyboardSelection: String?
    @Published var showHoldings = false
    @Published var revealed = false
    @Published var panelHeightLimit: CGFloat = 420
    @Published var panelContentHeight: CGFloat = 200
    @Published var previewDot = false
    @Published var message: String?
    @Published var error: String?
    var panelStatusHeight: CGFloat { error != nil || message != nil ? 25 : 0 }
    var panelViewportHeight: CGFloat {
        let available = max(80, panelHeightLimit - panelStatusHeight)
        // Keep detail tabs stable without reserving the whole 420pt panel.
        // Revealed holdings and cost legends need a little more room.
        if case .edit = route { return min(available, max(80, (revealed ? 370 : 350) - panelStatusHeight)) }
        return min(panelContentHeight, available)
    }
    var panelDisplayHeight: CGFloat { min(panelHeightLimit, panelViewportHeight + panelStatusHeight) }
    let dataURL: URL
    let intradayService: any IntradayProviding
    var currentDate: Date { clock() }
    private let file: StateFile
    private let service: any QuoteProviding
    private let notifications: any NotificationSending
    private let barkSender: any BarkSending
    private let barkKeys: any BarkKeyStoring
    private var cachedBarkKey: String?
    private var barkRetryAfter: [String: Date] = [:]
    private let clock: () -> Date
    private let scheduler: any RefreshScheduling
    private var started = false
    private var cacheURL: URL { dataURL.deletingLastPathComponent().appendingPathComponent("quotes-cache.json") }
    private var wakeObserver: NSObjectProtocol?
    private var processingAlerts = false
    private var navigationRevision = 0

    init(dataDirectory: URL? = nil, service: any QuoteProviding = QuoteService(),
         notifications: (any NotificationSending)? = nil, shortcutBackend: (any ShortcutRegistering)? = nil, scheduler: (any RefreshScheduling)? = nil, updateChecker: UpdateChecker? = nil, barkSender: (any BarkSending)? = nil, barkKeys: (any BarkKeyStoring)? = nil, intradayService: any IntradayProviding = IntradayService(), clock: @escaping () -> Date = Date.init) {
        self.updateChecker = updateChecker ?? UpdateChecker()
        // One backend allocates unique Carbon IDs across all three actions.
        let backend = shortcutBackend ?? CarbonShortcutBackend()
        self.shortcutManager = GlobalShortcutManager(backend: backend)
        self.previousShortcutManager = GlobalShortcutManager(backend: backend)
        self.nextShortcutManager = GlobalShortcutManager(backend: backend)
        self.scheduler = scheduler ?? RefreshScheduler()
        self.service = service
        self.intradayService = intradayService
        self.notifications = notifications ?? NotificationService()
        self.barkSender = barkSender ?? BarkService()
        self.barkKeys = barkKeys ?? BarkKeychain()
        self.clock = clock
        self.now = clock()
        let directory = dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StockBar", isDirectory: true)
        dataURL = directory.appendingPathComponent("state.json")
        file = StateFile(url: dataURL)
        do { state = try file.load() }
        catch { storageHealthy = false; self.error = "本地数据无法读取，已停止保存与提醒以保护持仓。\(error.localizedDescription)" }
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([String: Quote].self, from: data) {
            let ids = Set(state.items.map(\.id))
            quotes = cached.filter { ids.contains($0.key) && $0.value.isValid && $0.key == $0.value.symbol.rawValue }
        }
        for action in ShortcutAction.allCases {
            manager(for: action).onActivate = { [weak self] in
                guard let self else { return }
                if self.isRecordingShortcut { self.isRecordingShortcut = false; self.shortcutError = nil; return }
                switch action {
                case .togglePanel: self.onShortcutToggle?()
                case .previousStock: self.cycleStock(offset: -1)
                case .nextStock: self.cycleStock(offset: 1)
                }
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        restoreGlobalShortcut()
        Task { await updatePermission() }
        // Scheduling belongs to the app, so no panel/route/visibility checks appear here.
        scheduler.schedule(after: 0) { [weak self] in await self?.refresh() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
    }

    func stop() {
        started = false
        scheduler.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        shortcutManager.stop()
        previousShortcutManager.stop(); nextShortcutManager.stop()
    }

    func synchronizeClock() { now = clock() }

    private func scheduleNextRefresh() {
        guard started else { return }
        scheduler.cancel()
        now = clock()
        guard !state.items.isEmpty else { return }
        // A daily local wake keeps an expired-calendar warning accurate without network polling.
        let next = TradingSchedule.nextWake(after: now, interval: state.refreshIntervalSeconds)
            ?? now.addingTimeInterval(24 * 60 * 60)
        scheduler.schedule(after: max(0.01, next.timeIntervalSince(now))) { [weak self] in
            guard let self, self.started else { return }
            await self.refresh()
        }
    }

    private func saveQuoteCache() {
        guard let data = try? JSONEncoder().encode(quotes) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    var holdings: [WatchItem] { state.items.filter { $0.holding.quantity > 0 } }
    var summary: PortfolioSummary { PortfolioSummary(items: state.items, quotes: quotes) }
    var hasOldHoldings: Bool { holdings.contains { isOld($0.id) } }
    var marketLabel: String {
        guard TradingSchedule.isCalendarSupported(now) else { return "日历需更新" }
        return TradingSchedule.isOpen(now) ? "交易时段" : "休市"
    }
    var refreshDescription: String {
        guard TradingSchedule.isCalendarSupported(now) else { return "交易日历未覆盖当前年份，自动监测已暂停，可手动获取行情，请检查新版。" }
        return TradingSchedule.isOpen(now) ? "每 \(state.refreshIntervalSeconds) 秒监测，收起面板后继续。" : "休市暂停自动刷新，可手动获取行情；开市自动恢复监测。"
    }
    var latestTime: Date? { state.items.compactMap { quotes[$0.id]?.timestamp }.min() }
    var hasUnreadAlerts: Bool { previewDot || !state.unreadAlerts.isEmpty }
    func displayName(_ item: WatchItem) -> String { revealed ? item.name : (state.aliases[item.id] ?? "—") }
    func resetPrivacy() { keyboardSelection = nil; isRecordingShortcut = false; revealed = false; route = .home; message = nil }
    func closePanel() { resetPrivacy(); NotificationCenter.default.post(name: .closeStockPanel, object: nil) }
    func acknowledgeAlerts() {
        var next = state
        next.unreadAlerts = []
        if commit(next) { previewDot = false }
    }

    func isOld(_ id: String) -> Bool {
        guard let q = quotes[id] else { return true }
        return failedSymbols.contains(id) || QuoteDisplayPolicy.isOld(q, now: now)
    }

    func quoteLabel(_ id: String) -> String {
        guard let quote = quotes[id] else { return "等待行情" }
        let stamp = UI.time(quote.timestamp, full: MarketClock.day(quote.timestamp) != MarketClock.day(now))
        if failedSymbols.contains(id) { return "更新失败 · \(stamp) 旧行情" }
        if isOld(id) { return "历史/延迟行情 · \(stamp)" }
        return "\(MarketClock.isTradingTime(now) ? "行情" : "收盘/休市行情") · \(stamp)"
    }

    var menuTitle: String {
        // Legacy dailyProfit remains decodable, but never exposes holdings in the menu bar.
        guard state.menuMode == .stock || state.menuMode == .stockPrice else { return "" }
        guard let item = state.items.first(where: { $0.id == state.pinnedSymbol }) ?? state.items.first,
              let q = quotes[item.id] else { return "—" }
        let price = state.menuMode == .stockPrice ? " · \(UI.number(q.last, digits: item.symbol.priceFractionDigits))" : ""
        return "\(UI.number(q.percent, signed: true))%\(price)\(isOld(item.id) ? " · 旧" : "")"
    }

    func refresh(manually: Bool = false) async {
        guard !isRefreshing else { return }
        now = clock()
        defer { scheduleNextRefresh() }
        guard manually || TradingSchedule.isOpen(now) else { return }
        let requested = state.items.map(\.symbol)
        guard !requested.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false; now = clock() }
        do {
            let result = try await service.fetch(requested)
            now = clock()
            let current = Set(state.items.map(\.id))
            let ids = Set(requested.map(\.rawValue)).intersection(current)
            var accepted: [String: Quote] = [:]
            for id in ids {
                if let quote = result[id], quotes[id].map({ quote.timestamp >= $0.timestamp }) ?? true {
                    quotes[id] = quote
                    failedSymbols.remove(id)
                    accepted[id] = quote
                } else { failedSymbols.insert(id) }
            }
            if !ids.isEmpty && accepted.isEmpty { error = "未取得有效新行情，请检查网络或证券代码；旧行情不会触发提醒。" }
            else if !failedSymbols.isEmpty { error = "部分股票更新失败，已标记旧行情。" }
            else if storageHealthy { error = nil }
            saveQuoteCache()
            await processAlerts(accepted)
        } catch {
            failedSymbols.formUnion(requested.map(\.rawValue))
            self.error = "行情更新失败：\(error.localizedDescription)"
        }
    }

    func add(_ input: String) async -> Bool {
        guard !isAdding, storageHealthy else { return false }
        isAdding = true
        let revision = navigationRevision
        defer { isAdding = false }
        do {
            try Task.checkCancellation()
            let symbol = try StockSymbol(input)
            guard !state.items.contains(where: { $0.symbol == symbol }) else {
                error = "这只股票已在自选列表中。"; return false
            }
            let result = try await service.fetch([symbol])
            try Task.checkCancellation()
            guard revision == navigationRevision else { return false }
            guard let quote = result[symbol.rawValue] else { throw QuoteServiceError.empty }
            var next = state
            next.items.append(WatchItem(symbol: symbol, name: quote.name))
            if next.pinnedSymbol == nil { next.pinnedSymbol = symbol.rawValue }
            guard commit(next) else { return false }
            quotes[symbol.rawValue] = quote
            failedSymbols.remove(symbol.rawValue)
            now = clock()
            saveQuoteCache()
            scheduleNextRefresh()
            message = "已添加 \(state.aliases[symbol.rawValue] ?? "自选项")"
            return true
        } catch is CancellationError { return false }
        catch { if !Task.isCancelled, revision == navigationRevision { self.error = error.localizedDescription }; return false }
    }

    @discardableResult func clearHolding(_ id: String) -> Bool {
        guard let index = state.items.firstIndex(where: { $0.id == id }) else { return false }
        var next = state
        next.items[index].holding = Holding()
        guard commit(next) else { return false }
        message = "此项持仓已清空，自选与提醒已保留。"
        return true
    }

    func saveHolding(id: String, quantity: String, cost: String, pin: Bool, alias: String? = nil) -> Bool {
        guard let i = state.items.firstIndex(where: { $0.id == id }) else { return false }
        guard quantity.range(of: #"^\d+$"#, options: .regularExpression) != nil,
              let shares = Int(quantity), shares <= 100_000_000,
              let average = UI.decimal(cost), average <= 10_000_000 else {
            error = "持仓数量需为 0–1 亿的整数，成本需为 0–1000 万元，最多 4 位小数。"; return false
        }
        var next = state
        if let alias {
            let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 8,
                  !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
                  !state.aliases.contains(where: { $0.key != id && $0.value == value }) else {
                error = "代号需为 1–8 个非空白字符，且不能重复。"; return false
            }
            next.aliases[id] = value
        }
        next.items[i].holding = Holding(quantity: shares, averageCost: average)
        if pin { next.pinnedSymbol = id }
        else if next.pinnedSymbol == id { next.pinnedSymbol = next.items.first(where: { $0.id != id })?.id ?? id }
        guard commit(next) else { return false }
        message = "持仓已保存"; return true
    }

    func saveRule(id: String, upEnabled: Bool, downEnabled: Bool, up: String, down: String, delivery: AlertDelivery? = nil, price: PriceAlertRule? = nil, holding: HoldingAlertRule? = nil) async -> Bool {
        guard !Task.isCancelled, state.items.contains(where: { $0.id == id }) else { return false }
        let revision = navigationRevision
        guard let upValue = UI.decimal(up), let downValue = UI.decimal(down),
              upValue > 0, downValue > 0, upValue <= 999, downValue <= 999 else {
            error = "提醒阈值需大于 0 且不超过 999%。"; return false
        }
        let channel = delivery ?? state.items.first(where: { $0.id == id })!.rule.delivery
        var rule = state.items.first(where: { $0.id == id })!.rule
        rule.upEnabled = upEnabled; rule.downEnabled = downEnabled
        rule.upThreshold = upValue; rule.downThreshold = downValue; rule.delivery = channel
        if let price { rule.price = price }
        if let holding { rule.holding = holding }
        do { try rule.validate() }
        catch { self.error = error.localizedDescription; return false }
        if channel == .bark && rule.hasEnabledRule {
            do { _ = try configuredBarkKey() }
            catch { self.error = error.localizedDescription; return false }
        }
        if channel == .system && rule.hasEnabledRule {
            await updatePermission()
            guard !Task.isCancelled, revision == navigationRevision else { return false }
            if notificationStatus == .notDetermined {
                do { _ = try await notifications.requestPermission() }
                catch { if !Task.isCancelled, revision == navigationRevision { self.error = "无法申请通知权限：\(error.localizedDescription)" }; return false }
                guard !Task.isCancelled, revision == navigationRevision else { return false }
                await updatePermission()
            }
        }
        guard !Task.isCancelled, revision == navigationRevision, let i = state.items.firstIndex(where: { $0.id == id }) else { return false }
        var next = state
        next.items[i].rule = rule
        guard commit(next) else { return false }
        message = channel == .system && notificationStatus == .denied && rule.hasEnabledRule
            ? "规则已保存；需在系统设置允许通知后才能收到提醒。" : "提醒已保存，下一次有效行情开始判断。"
        return true
    }

    func refreshBarkStatus() {
        // Opening settings must never access Keychain or trigger authentication.
        hasBarkKey = cachedBarkKey != nil
    }

    @discardableResult func saveBarkSettings(_ configuration: BarkConfiguration, newKey: String) -> Bool {
        guard storageHealthy else { return false }
        var oldKey: String?
        var changedKey = false
        var resolvedKey = cachedBarkKey
        do {
            try configuration.validate()
            let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty || configuration.enabled {
                oldKey = try cachedBarkKey ?? barkKeys.read(allowInteraction: true)
                let effective = key.isEmpty ? oldKey : key
                guard let effective else { throw BarkFailure.missingKey }
                try BarkFailure.validateKey(effective)
                resolvedKey = effective
                if !key.isEmpty { try barkKeys.write(key); changedKey = true }
            }
            var next = state; next.bark = configuration
            guard commit(next) else {
                if changedKey { try barkKeys.write(oldKey) }
                return false
            }
            cachedBarkKey = resolvedKey
            hasBarkKey = resolvedKey != nil
            barkRetryAfter.removeAll()
            message = configuration.enabled ? "Bark 已保存；在各自选项的提醒方式中选择 Bark 后生效。" : "Bark 已关闭；使用 Bark 的提醒暂停推送。"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func removeBarkKey() {
        var next = state; next.bark.enabled = false
        guard commit(next) else { return }
        cachedBarkKey = nil; hasBarkKey = false
        do { try barkKeys.write(nil); barkRetryAfter.removeAll(); message = "Bark 已关闭，设备密钥已删除。" }
        catch { self.error = error.localizedDescription }
    }

    private func configuredBarkKey() throws -> String {
        guard state.bark.enabled else { throw BarkFailure.missingKey }
        if let key = cachedBarkKey { return key }
        guard let key = try barkKeys.read(allowInteraction: false) else { hasBarkKey = false; throw BarkFailure.missingKey }
        try BarkFailure.validateKey(key)
        cachedBarkKey = key; hasBarkKey = true
        return key
    }

    func testBark() async {
        let revision = navigationRevision
        guard !Task.isCancelled, storageHealthy else { return }
        do {
            let key = try configuredBarkKey()
            let item = state.items.first(where: { $0.id == state.pinnedSymbol }) ?? state.items.first
            let quote = item.flatMap { quotes[$0.id] }
            let message = try BarkMessage(testConfiguration: state.bark, symbol: item?.symbol, quote: quote, name: item?.name)
            guard !Task.isCancelled, revision == navigationRevision else { return }
            try await barkSender.send(configuration: state.bark, key: key, message: message)
            guard !Task.isCancelled, revision == navigationRevision else { return }
            self.message = "Bark 已确认接收测试通知；手表显示仍取决于 iPhone 锁屏、通知镜像和专注模式。"
        } catch {
            if !Task.isCancelled, revision == navigationRevision { self.error = error.localizedDescription }
        }
    }

    func restoreGlobalShortcut() {
        guard storageHealthy else { return }
        var failed: [String] = []
        for action in ShortcutAction.allCases {
            do { try manager(for: action).replace(shortcut(for: action)) { _ in true } }
            catch { failed.append(action.title) }
        }
        shortcutError = failed.isEmpty ? nil : failed.joined(separator: "、") + "快捷键不可用，请重新设置。"
    }

    func shortcut(for action: ShortcutAction) -> GlobalShortcut? {
        switch action {
        case .togglePanel: return state.globalShortcut
        case .previousStock: return state.previousStockShortcut
        case .nextStock: return state.nextStockShortcut
        }
    }

    func manager(for action: ShortcutAction) -> GlobalShortcutManager {
        switch action {
        case .togglePanel: return shortcutManager
        case .previousStock: return previousShortcutManager
        case .nextStock: return nextShortcutManager
        }
    }

    @discardableResult func setGlobalShortcut(_ shortcut: GlobalShortcut?, action: ShortcutAction = .togglePanel) -> Bool {
        guard shortcut == nil || !ShortcutAction.allCases.contains(where: { $0 != action && self.shortcut(for: $0) == shortcut }) else {
            shortcutError = "这组快捷键已用于其他操作，请换一组。"; return false
        }
        do {
            let saved = try manager(for: action).replace(shortcut) { value in
                var next = state
                switch action {
                case .togglePanel: next.globalShortcut = value
                case .previousStock: next.previousStockShortcut = value
                case .nextStock: next.nextStockShortcut = value
                }
                return commit(next)
            }
            if saved { shortcutError = nil; isRecordingShortcut = false }
            return saved
        } catch { shortcutError = error.localizedDescription; return false }
    }

    func remove(_ id: String) {
        var next = state
        next.items.removeAll { $0.id == id }
        next.aliases.removeValue(forKey: id)
        next.unreadAlerts.removeAll { $0.symbol.rawValue == id }
        if next.pinnedSymbol == id { next.pinnedSymbol = next.items.first?.id }
        // Keep today's receipt keys so removing/re-adding a stock cannot bypass deduplication.
        guard commit(next) else { return }
        quotes.removeValue(forKey: id); failedSymbols.remove(id)
        saveQuoteCache()
        scheduleNextRefresh()
        route = .home; message = "已移出自选"
    }

    @discardableResult func saveRefreshInterval(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
              let interval = Int(trimmed), (5...300).contains(interval) else {
            error = "刷新间隔需为 5–300 秒的整数。"; return false
        }
        var next = state
        next.refreshIntervalSeconds = interval
        guard commit(next) else { return false }
        scheduleNextRefresh()
        return true
    }

    func moveItem(_ id: String, offset: Int) {
        guard [-1, 1].contains(offset), let index = state.items.firstIndex(where: { $0.id == id }),
              state.items.indices.contains(index + offset) else { return }
        var next = state
        next.items.swapAt(index, index + offset)
        _ = commit(next)
    }

    func pinStock(_ id: String) {
        guard state.items.contains(where: { $0.id == id }) else { return }
        var next = state
        next.pinnedSymbol = id
        // Selecting a stock must not silently turn off icon-only privacy mode.
        _ = commit(next)
    }

    func cycleStock(offset: Int) {
        guard state.items.count > 1, offset == -1 || offset == 1 else { return }
        let index = state.items.firstIndex(where: { $0.id == state.pinnedSymbol }) ?? 0
        let next = (index + offset + state.items.count) % state.items.count
        pinStock(state.items[next].id)
    }

    func saveSettings(mode: MenuMode? = nil, compact: Bool? = nil) {
        var next = state
        if let mode { next.menuMode = mode }
        if let compact { next.compactRows = compact }
        _ = commit(next)
    }

    @discardableResult private func commit(_ next: SavedState) -> Bool {
        guard storageHealthy else { error = "本地存储异常，请先检查数据文件；现有数据不会被覆盖。"; return false }
        var normalized = next
        normalized.assignMissingAliases()
        do { try file.save(normalized); state = normalized; error = nil; return true }
        catch { storageHealthy = false; self.error = "保存失败，提醒已停用以避免重复：\(error.localizedDescription)"; return false }
    }

    private func processAlerts(_ freshQuotes: [String: Quote]) async {
        guard storageHealthy, !processingAlerts, TradingSchedule.isOpen(clock()) else { return }
        processingAlerts = true
        defer { processingAlerts = false }
        let candidates = AlertEvaluator.candidates(items: state.items, quotes: freshQuotes, delivered: state.delivered, now: clock())
        barkRetryAfter = barkRetryAfter.filter { $0.value > clock() }
        for candidate in candidates {
            guard storageHealthy else { break }
            guard let delivery = state.items.first(where: { $0.id == candidate.symbol.rawValue })?.rule.delivery else { continue }
            if delivery == .bark {
                guard state.bark.enabled, barkRetryAfter[candidate.key] == nil else { continue }
            }
            if delivery == .system {
                await updatePermission()
                guard notificationStatus == .authorized || notificationStatus == .provisional else { continue }
            }
            // Settings may change while macOS handles an asynchronous notification request.
            guard let currentCandidate = AlertEvaluator.candidates(items: state.items, quotes: freshQuotes, delivered: state.delivered, now: clock())
                .first(where: { $0.key == candidate.key && $0.day == candidate.day }),
                state.items.first(where: { $0.id == candidate.symbol.rawValue })?.rule.delivery == delivery else { continue }
            do {
                if delivery == .system {
                    let alias = state.aliases[candidate.symbol.rawValue] ?? "自选项"
                    try await notifications.send(identifier: "\(candidate.day)|\(candidate.key)", title: "提醒", body: "\(alias) 已达到设置条件，打开速览查看。")
                }
                if delivery == .bark {
                    guard let quote = freshQuotes[candidate.symbol.rawValue] else { continue }
                    let key = try configuredBarkKey()
                    let message = try BarkMessage(configuration: state.bark, candidate: currentCandidate, quote: quote)
                    try await barkSender.send(configuration: state.bark, key: key, message: message)
                    barkRetryAfter.removeValue(forKey: candidate.key)
                }
                var next = state
                next.delivered = next.delivered.filter { $0.value == candidate.day }
                next.delivered[candidate.key] = candidate.day
                next.unreadAlerts = next.unreadAlerts.filter { $0.day == candidate.day }
                if delivery == .silent || delivery == .bark, let q = freshQuotes[candidate.symbol.rawValue] {
                    next.unreadAlerts.append(PendingAlert(key: candidate.key, day: candidate.day, symbol: candidate.symbol, percent: q.percent, triggerValue: currentCandidate.value))
                }
                guard commit(next) else { break }
            } catch {
                if delivery == .bark { barkRetryAfter[candidate.key] = clock().addingTimeInterval(60) }
                self.error = "提醒发送失败：\(error.localizedDescription)"
            }
        }
    }

    func updatePermission() async { notificationStatus = await notifications.status() }

    func testNotification() async {
        let revision = navigationRevision
        guard !Task.isCancelled else { return }
        do {
            await updatePermission()
            guard !Task.isCancelled, revision == navigationRevision else { return }
            if notificationStatus == .notDetermined {
                _ = try await notifications.requestPermission()
                guard !Task.isCancelled, revision == navigationRevision else { return }
                await updatePermission()
            }
            guard !Task.isCancelled, revision == navigationRevision else { return }
            guard notificationStatus == .authorized || notificationStatus == .provisional else {
                error = "通知权限未开启。请在系统设置 → 通知 → Tickfin 中允许通知。"; return
            }
            try await notifications.send(identifier: "manual-test", title: "测试提醒", body: "这是手动测试，不代表达到提醒条件。")
            guard !Task.isCancelled, revision == navigationRevision else { return }
            message = "测试通知已提交；横幅显示受系统通知和专注模式设置影响。"
        } catch { if !Task.isCancelled, revision == navigationRevision { self.error = "测试通知失败：\(error.localizedDescription)" } }
    }

    func revealData() { NSWorkspace.shared.activateFileViewerSelecting([dataURL]) }
    func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
}
