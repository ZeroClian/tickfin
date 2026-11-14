import AppKit
import SwiftUI
import StockCore

struct PanelHeader: View {
    @ObservedObject var store: AppStore
    let title: String
    let subtitle: String
    var showPrivacy = false
    var backRoute: PanelRoute = .home
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                IconButton(symbol: "chevron.left", label: backRoute == .home ? "返回速览" : "返回偏好") { store.route = backRoute }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 10)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if showPrivacy {
                    IconButton(symbol: store.revealed ? "eye" : "eye.slash", label: "显示或隐藏名称和持仓") { store.revealed.toggle() }
                }
                IconButton(symbol: "xmark", label: "立即收起") { store.closePanel() }
            }.padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
        }
    }
}

struct AddStockView: View {
    @ObservedObject var store: AppStore
    @ViewState private var code = ""
    @ViewState private var addTask: Task<Void, Never>?
    @ViewState private var addingID: String?
    @StateObject private var search: StockSearchModel
    @FocusState private var focused: Bool
    init(store: AppStore, search: StockSearchModel? = nil) {
        self.store = store
        _search = StateObject(wrappedValue: search ?? StockSearchModel())
    }
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(store: store, title: "添加", subtitle: "")
            VStack(alignment: .leading, spacing: 10) {
                TextField("代码 / 拼音简写，如 NDSD", text: $code)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .accessibilityLabel("股票或 ETF 代码、拼音首字母")
                    .onChange(of: code) { search.updateQuery($0) }
                    .onSubmit { search.updateQuery(code, immediately: true) }
                if search.isSearching {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("搜索中…").foregroundColor(.secondary)
                    }
                }
                if let message = search.message {
                    Text(message).font(.system(size: 10)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重新搜索") { search.updateQuery(code, immediately: true) }
                }
                if !search.results.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(search.results) { result in
                            resultRow(result)
                            if result.id != search.results.last?.id { Divider() }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("完成") { store.route = .home }
                }
            }.font(.system(size: 11)).controlSize(.small).padding(12)
        }.onAppear { focused = true }.onDisappear { addTask?.cancel(); search.cancel() }
    }

    private func resultRow(_ result: StockSearchResult) -> some View {
        let added = store.state.items.contains { $0.id == result.id }
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name).lineLimit(1).help(result.name)
                Text(result.symbol.marketName + " " + result.symbol.code)
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if addingID == result.id {
                ProgressView().controlSize(.mini).frame(width: 24, height: 28)
            } else {
                Button { add(result) } label: {
                    Image(systemName: added ? "checkmark" : "plus")
                        .font(.system(size: 12)).frame(width: 24, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .disabled(added || store.isAdding || !store.storageHealthy)
                    .help(added ? "已添加" : "添加 " + result.name)
                    .accessibilityLabel((added ? "已添加 " : "添加 ") + result.name + " " + result.symbol.code)
            }
        }.padding(.vertical, 6)
    }

    private func add(_ result: StockSearchResult) {
        guard addTask == nil else { return }
        addingID = result.id
        store.error = nil
        addTask = Task {
            defer { addTask = nil; addingID = nil }
            if await store.add(result.id), !Task.isCancelled, store.route == .add {
                store.showHoldings = false
            }
        }
    }
}

enum StockDetailTab: Hashable {
    case line, fiveMinute, holding, alerts
    var chartMode: IntradayMode? {
        switch self {
        case .line: return .line
        case .fiveMinute: return .fiveMinute
        case .holding, .alerts: return nil
        }
    }
}

struct StockEditor: View {
    @ObservedObject var store: AppStore
    let item: WatchItem
    @ViewState private var detailTab: StockDetailTab
    @StateObject private var chart: IntradayChartModel
    private var alerts: Bool { detailTab == .alerts }
    @ViewState private var alias: String
    @ViewState private var shares: String
    @ViewState private var cost: String
    @ViewState private var pin: Bool
    @ViewState private var upEnabled: Bool
    @ViewState private var downEnabled: Bool
    @ViewState private var up: String
    @ViewState private var down: String
    @ViewState private var delivery: AlertDelivery
    @ViewState private var alertSection: Int
    @ViewState private var priceRule: PriceAlertRule
    @ViewState private var holdingRule: HoldingAlertRule
    @ViewState private var abovePrice: String
    @ViewState private var belowPrice: String
    @ViewState private var profitTarget: String
    @ViewState private var lossTarget: String
    @ViewState private var saving = false
    @ViewState private var saveTask: Task<Void, Never>?
    @ViewState private var confirmRemoval = false
    @ViewState private var confirmClearHolding = false

    init(store: AppStore, item: WatchItem, initialAlerts: Bool, initialTab: StockDetailTab? = nil, chartModel: IntradayChartModel? = nil) {
        self.store = store; self.item = item
        _detailTab = ViewState(initialValue: initialTab ?? (initialAlerts ? .alerts : .line))
        _chart = StateObject(wrappedValue: chartModel ?? IntradayChartModel(service: store.intradayService, clock: { store.currentDate }))
        _alias = ViewState(initialValue: store.state.aliases[item.id] ?? "")
        _shares = ViewState(initialValue: String(item.holding.quantity))
        _cost = ViewState(initialValue: UI.input(item.holding.averageCost))
        _pin = ViewState(initialValue: item.id == (store.state.pinnedSymbol ?? store.state.items.first?.id))
        _upEnabled = ViewState(initialValue: item.rule.upEnabled)
        _downEnabled = ViewState(initialValue: item.rule.downEnabled)
        _up = ViewState(initialValue: UI.input(item.rule.upThreshold))
        _down = ViewState(initialValue: UI.input(item.rule.downThreshold))
        _delivery = ViewState(initialValue: item.rule.delivery)
        _priceRule = ViewState(initialValue: item.rule.price)
        _holdingRule = ViewState(initialValue: item.rule.holding)
        _abovePrice = ViewState(initialValue: UI.input(item.rule.price.above))
        _belowPrice = ViewState(initialValue: UI.input(item.rule.price.below))
        _profitTarget = ViewState(initialValue: UI.input(item.rule.holding.profit))
        _lossTarget = ViewState(initialValue: UI.input(item.rule.holding.loss))
        _alertSection = ViewState(initialValue: item.rule.upEnabled || item.rule.downEnabled ? 0 :
            item.rule.price.aboveEnabled || item.rule.price.belowEnabled ? 1 :
            item.rule.holding.profitEnabled || item.rule.holding.lossEnabled ? 2 : 0)
    }
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(store: store, title: store.displayName(item),
                        subtitle: store.revealed ? item.symbol.marketName + " " + item.symbol.code : "", showPrivacy: true)
            priceSummary
            // The regular native control has a 296pt minimum width. Small keeps
            // all four segments inside the 256pt content area on every update.
            Picker("个股详情", selection: $detailTab) {
                Text("分时").tag(StockDetailTab.line)
                Text("5 分钟 K").tag(StockDetailTab.fiveMinute)
                Text("持仓").tag(StockDetailTab.holding)
                Text("提醒").tag(StockDetailTab.alerts)
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 256)
                .padding(.horizontal, 12).padding(.top, 10).disabled(saving)
            if let mode = detailTab.chartMode {
                IntradayChartSection(model: chart, mode: mode, item: item, revealed: store.revealed,
                                     interval: store.state.refreshIntervalSeconds, now: store.currentDate) { detailTab = .alerts }
            } else {
                editorForm
            }
        }
        .confirmationDialog("移出 \(store.displayName(item))？", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("移出并删除本地持仓", role: .destructive) { store.remove(item.id) }
            Button("取消", role: .cancel) {}
        } message: { Text("本地持仓与提醒设置将一并删除，不影响券商账户。") }
        .onDisappear { saveTask?.cancel() }
    }
    private var editorForm: some View {
            VStack(alignment: .leading, spacing: alerts ? 8 : 10) {
                if alerts { alertForm } else { holdingForm }
                HStack(spacing: 7) {
                    if !alerts {
                        Button("移出") { confirmRemoval = true }.buttonStyle(.plain).disabled(!store.storageHealthy)
                        Button("清空持仓") { confirmClearHolding = true }
                            .buttonStyle(.plain)
                            .disabled(saving || !store.storageHealthy || !store.state.items.contains { $0.id == item.id && $0.holding != Holding() })
                            .confirmationDialog("清空 \(store.displayName(item)) 的持仓？", isPresented: $confirmClearHolding, titleVisibility: .visible) {
                                Button("清空持仓", role: .destructive) {
                                    if store.clearHolding(item.id) { shares = "0"; cost = "0" }
                                }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("仅将此项的数量和成本归零，保留自选、代号及提醒。确认后立即保存，取消编辑不会撤销。")
                            }
                    }
                    Spacer(minLength: 0)
                    if saving { ProgressView().controlSize(.mini) }
                    Button("取消") { store.route = .home }
                    Button("保存") { save() }.keyboardShortcut("s", modifiers: .command).disabled(saving || !store.storageHealthy)
                }.padding(.top, 2)
            }.font(.system(size: 11)).controlSize(.small).padding(12)
    }
    @ViewBuilder private var priceSummary: some View {
        if let mode = detailTab.chartMode {
            IntradayPriceSummary(model: chart, symbol: item.symbol, mode: mode, now: store.currentDate)
        } else {
            let quote = [store.quotes[item.id], chart.latestQuote(for: item.symbol)].compactMap { $0 }.max { $0.timestamp < $1.timestamp }
            StockPriceSummary(symbol: item.symbol, mode: .line, readout: quote.map(IntradayReadout.init(quote:)),
                dateLabel: quote == store.quotes[item.id] ? store.quoteLabel(item.id) :
                    quote.map { (MarketClock.day($0.timestamp) == MarketClock.day(store.currentDate) ? "行情 · " : "历史行情 · ") + UI.time($0.timestamp, full: true) } ?? "等待行情",
                isLoading: store.isRefreshing)
        }
    }
    private var holdingForm: some View {
        Group {
            entry("代号", value: $alias, numeric: false)
            if store.revealed {
                entry(item.symbol.isETF ? "持仓份数" : "持仓股数", value: $shares)
                entry("平均成本", value: $cost)
            } else {
                HStack {
                    Text("持仓与成本").foregroundColor(.secondary)
                    Spacer()
                    Text("••••").accessibilityLabel("已隐藏")
                }
                Button("显示持仓以编辑") { store.revealed = true }
            }
            Toggle("设为状态栏选中项", isOn: $pin).toggleStyle(.checkbox)
        }
    }
    private var alertForm: some View {
        Group {
            Picker("提醒条件", selection: $alertSection) {
                Text("涨跌幅").tag(0); Text("价格").tag(1); Text("盈亏").tag(2); Text("设置").tag(3)
            }.pickerStyle(.segmented).labelsHidden()
            if alertSection == 0 {
                threshold("上涨达到", enabled: $upEnabled, value: $up)
                threshold("下跌达到", enabled: $downEnabled, value: $down)
            } else if alertSection == 1 {
                threshold("价格涨到", enabled: $priceRule.aboveEnabled, value: $abovePrice, unit: "元")
                threshold("价格跌到", enabled: $priceRule.belowEnabled, value: $belowPrice, unit: "元")
            } else if alertSection == 2 {
                if store.revealed {
                    Picker("浮动盈亏", selection: $holdingRule.unit) {
                        Text("金额（元）").tag(HoldingAlertUnit.amount)
                        Text("比例（%）").tag(HoldingAlertUnit.percent)
                    }
                    threshold("盈利达到", enabled: $holdingRule.profitEnabled, value: $profitTarget, unit: holdingRule.unit == .amount ? "元" : "%")
                    threshold("亏损达到", enabled: $holdingRule.lossEnabled, value: $lossTarget, unit: holdingRule.unit == .amount ? "元" : "%")
                } else {
                    Button("显示盈亏提醒以编辑") { store.revealed = true }
                }
            }
            Text(enabledAlertSummary).font(.system(size: 9)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if alertSection == 3 {
                Picker("提醒方式", selection: $delivery) {
                    Text("静默小点").tag(AlertDelivery.silent)
                    Text("系统通知").tag(AlertDelivery.system)
                    Text("Bark 推送").tag(AlertDelivery.bark)
                }
            }
        }
    }
    private var enabledAlertSummary: String {
        let flags = [(upEnabled, "涨幅"), (downEnabled, "跌幅"),
                     (priceRule.aboveEnabled, "涨到"), (priceRule.belowEnabled, "跌到"),
                     (holdingRule.profitEnabled, "盈利"), (holdingRule.lossEnabled, "亏损")]
        let labels = flags.filter { $0.0 }.map { $0.1 }
        return labels.isEmpty ? "尚未开启提醒条件" : "已开启：" + labels.joined(separator: "、")
    }
    private func entry(_ title: String, value: Binding<String>, numeric: Bool = true) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundColor(.secondary)
            Spacer(minLength: 4)
            TextField(numeric ? "0" : "GZMT", text: value)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .monospacedDigit().frame(width: 142).accessibilityLabel(title)
        }
    }
    private func threshold(_ title: String, enabled: Binding<Bool>, value: Binding<String>, unit: String = "%") -> some View {
        HStack(spacing: 6) {
            Toggle(title, isOn: enabled).toggleStyle(.checkbox)
            Spacer(minLength: 0)
            TextField("3", text: value).textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing).monospacedDigit().frame(width: 65)
                .disabled(!enabled.wrappedValue).accessibilityLabel(title + "（" + unit + "）")
            Text(unit).foregroundColor(.secondary)
        }
    }
    private func save() {
        guard !saving else { return }
        store.error = nil
        if alerts {
            guard let above = UI.decimal(abovePrice), let below = UI.decimal(belowPrice),
                  let profit = UI.decimal(profitTarget), let loss = UI.decimal(lossTarget),
                  above > 0, below > 0, profit > 0, loss > 0 else {
                store.error = "价格和盈亏阈值需填写大于零的数值，最多四位小数。"; return
            }
            var price = priceRule; price.above = above; price.below = below
            var holding = holdingRule; holding.profit = profit; holding.loss = loss
            saving = true
            let sourceRoute = store.route
            saveTask = Task {
                if await store.saveRule(id: item.id, upEnabled: upEnabled, downEnabled: downEnabled, up: up, down: down, delivery: delivery, price: price, holding: holding),
                   !Task.isCancelled, store.route == sourceRoute { store.route = .home }
                saving = false
            }
        } else if store.saveHolding(id: item.id, quantity: shares, cost: cost, pin: pin, alias: alias) { store.route = .home }
    }
}

extension SettingsSection {
    var title: String {
        switch self {
        case .appearance: return "显示与快捷键"
        case .refresh: return "行情刷新"
        case .notifications: return "提醒通知"
        case .bark: return "Bark 推送"
        case .updates: return "版本更新"
        case .data: return "使用说明与数据"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    var section: SettingsSection? = nil
    @ViewState private var testing = false
    @ViewState private var testTask: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(store: store, title: section?.title ?? "偏好", subtitle: "",
                        backRoute: section == nil ? .home : .settings)
            VStack(alignment: .leading, spacing: 10) {
                if let section {
                    settingsContent(section)
                } else {
                    entry(.appearance, icon: "keyboard", detail: "状态栏模式 · 完整快捷键清单")
                    entry(.refresh, icon: "arrow.clockwise", detail: "\(store.state.refreshIntervalSeconds) 秒 · 休市暂停")
                    entry(.notifications, icon: "bell", detail: "触发规则 · 通知方式")
                    entry(.bark, icon: "iphone", detail: store.state.bark.enabled ? "已启用 · 连接与模板" : "手机与手表 · 未启用")
                    entry(.updates, icon: "arrow.down.circle", detail: "当前版本 " + store.updateChecker.currentVersion)
                    entry(.data, icon: "book.closed", detail: "操作 · 图表 · 持仓计算")
                    Divider()
                    HStack {
                        Text("Tickfin").foregroundColor(.secondary)
                        Spacer()
                        Button("退出") { NSApp.terminate(nil) }
                    }
                }
            }.font(.system(size: 11)).controlSize(.small).padding(12)
        }.task { if section == .notifications { await store.updatePermission() } }
            .onDisappear { testTask?.cancel() }
    }
    private func entry(_ section: SettingsSection, icon: String, detail: String) -> some View {
        Button {
            store.message = nil; store.route = .settingsPage(section)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 18).foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title)
                    Text(detail).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundColor(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func settingsContent(_ section: SettingsSection) -> some View {
        switch section {
        case .appearance:
            Picker("状态栏", selection: Binding(get: { store.state.menuMode == .dailyProfit ? MenuMode.icon : store.state.menuMode }, set: { store.saveSettings(mode: $0) })) {
                Text("仅图标").tag(MenuMode.icon)
                Text("仅涨跌幅").tag(MenuMode.stock)
                Text("涨跌幅＋现价").tag(MenuMode.stockPrice)
            }.disabled(!store.storageHealthy)
            Text("名称默认代号，金额默认隐藏。\n收起后恢复隐藏；按 Esc 可立即收起。")
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ShortcutSettingsView(store: store)
        case .refresh:
            RefreshSettingsView(store: store)
            Button(store.isRefreshing ? "刷新中…" : "立即刷新") { Task { await store.refresh(manually: true) } }
                .disabled(store.isRefreshing || store.state.items.isEmpty)
        case .notifications:
            DisclosureGroup("触发规则") {
                Text("涨跌幅、价格和盈亏条件可同时启用。达到或越过阈值即满足，每条规则每天一次；修改阈值视为新规则。保存时已达标的条件，在下一次有效行情刷新时判断。\n\n盈亏按单项持仓的浮动盈亏计算，亏损阈值填正数；数量或成本为零时暂停盈亏提醒。提醒按刷新间隔采样，两次刷新之间短暂触及阈值可能不会触发。\n\n收起面板后继续监测，电脑休眠、应用退出、休市或行情过旧时不提醒。")
                    .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("静默提醒").fontWeight(.medium)
            Text("只亮状态栏小点，无横幅和声音。").font(.system(size: 10)).foregroundColor(.secondary)
            HStack {
                Button("测试小点") { store.previewDot = true; store.message = "静默测试：状态栏已亮小点，没有发送系统通知。" }
                Button("查看提醒") { store.route = .inbox }
            }
            Divider()
            Text("系统通知 · " + permissionText).fontWeight(.medium)
            Text("仅对选择此方式的自选项发送，使用代号、不含金额。需要通知权限，专注模式可能影响横幅。")
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("测试通知") { testing = true; testTask = Task { await store.testNotification(); testing = false } }.disabled(testing)
                Button("通知设置") { store.openNotificationSettings() }
            }
            Divider()
            Text("Bark 推送").fontWeight(.medium)
            Text("先在 Bark 推送中配置连接，再为自选项选择此方式；通知内容使用该页的模板，并保留本机未读提醒。")
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Bark 设置") { store.route = .settingsPage(.bark) }
        case .bark:
            BarkSettingsView(store: store)
        case .updates:
            UpdateSettingsView(checker: store.updateChecker)
        case .data:
            UsageGuideView()
            Divider()
            Text("本机数据").fontWeight(.medium)
            Text("持仓、设置与行情缓存仅保存在本机。行情可能延迟，以券商数据为准。")
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("查看数据文件") { store.revealData() }
        }
    }
    private var permissionText: String {
        switch store.notificationStatus {
        case .authorized, .provisional: return "已允许"
        case .denied: return "未允许"
        default: return "未申请"
        }
    }
}

struct RefreshSettingsView: View {
    @ObservedObject var store: AppStore
    @ViewState private var interval = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前间隔 · \(store.state.refreshIntervalSeconds) 秒")
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    TextField("5–300", text: $interval).frame(width: 58)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("刷新间隔秒数")
                        .onSubmit { _ = store.saveRefreshInterval(interval) }
                    Text("秒")
                    Spacer(minLength: 0)
                    Button("保存") { _ = store.saveRefreshInterval(interval) }
                        .disabled(!store.storageHealthy)
                }
                Text(store.refreshDescription)
                Text("5–300 秒；间隔越长，提醒可能越晚。午休、周末和节假日暂停自动刷新；手动刷新不受时段限制。")
                Text("内置 2026 年交易日历，超出范围会暂停并提示更新。")
            }.font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }.onAppear { interval = String(store.state.refreshIntervalSeconds) }
    }
}
