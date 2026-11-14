import SwiftUI
import StockCore

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelView: View {
    @ObservedObject var store: AppStore
    private var hasStatus: Bool { store.error != nil || store.message != nil }
    var body: some View {
        VStack(spacing: 0) {
            // Legacy macOS scrollers add a 17pt gutter to fixed-width content,
            // widening this view to 297pt and shifting it inside the 280pt popover.
            // Keep the viewport width stable; wheel/trackpad scrolling still works.
            ScrollView(.vertical, showsIndicators: false) {
                content.frame(width: 280).fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    })
            }
            .id(store.route)
            .frame(height: store.panelViewportHeight)
            .onPreferenceChange(ContentHeightKey.self) { height in
                if height > 0 && abs(store.panelContentHeight - height) > 0.5 { store.panelContentHeight = height }
            }
            if hasStatus {
                Divider()
                HStack(spacing: 4) {
                    Button { store.route = .details } label: {
                        HStack(spacing: 5) {
                            Image(systemName: store.error == nil ? "info.circle" : "exclamationmark.circle")
                            Text(store.error == nil ? "操作结果 · 查看" : "需要处理 · 查看")
                        }.font(.system(size: 10)).lineLimit(1)
                    }.buttonStyle(.plain)
                    Spacer(minLength: 0)
                    if store.storageHealthy {
                        IconButton(symbol: "xmark", label: "关闭提示") { store.message = nil; store.error = nil }
                    }
                }.padding(.horizontal, 12).frame(height: 24)
            }
        }.frame(width: 280).background(UI.background).tint(.primary)
            .onExitCommand { store.closePanel() }
    }
    @ViewBuilder private var content: some View {
        switch store.route {
        case .home: HomeView(store: store)
        case .add: AddStockView(store: store)
        case .edit(let id, let alerts):
            if let item = store.state.items.first(where: { $0.id == id }) {
                StockEditor(store: store, item: item, initialAlerts: alerts).id(id + String(alerts))
            } else { HomeView(store: store) }
        case .settings: SettingsView(store: store)
        case .settingsPage(let section): SettingsView(store: store, section: section)
        case .sorting: WatchlistSortView(store: store)
        case .details:
            VStack(spacing: 0) {
                PanelHeader(store: store, title: "详情", subtitle: "")
                Text(store.error ?? store.message ?? "暂无消息")
                    .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        case .inbox: AlertInbox(store: store)
        }
    }
}

struct HomeView: View {
    @ObservedObject var store: AppStore
    private var items: [WatchItem] { store.showHoldings ? store.holdings : store.state.items }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                tab("自选", holdings: false)
                tab("持仓", holdings: true)
                Spacer(minLength: 0)
                if !store.state.items.isEmpty {
                    Menu {
                        ForEach(store.state.items) { item in
                            Button { store.pinStock(item.id) } label: {
                                if store.state.pinnedSymbol == item.id { Label(store.displayName(item), systemImage: "checkmark") }
                                else { Text(store.displayName(item)) }
                            }
                        }
                    } label: { Image(systemName: "pin").font(.system(size: 11)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 24)
                    .help("快速切换状态栏关注项").accessibilityLabel("切换状态栏关注项")
                    .disabled(!store.storageHealthy)
                    IconButton(symbol: "arrow.up.arrow.down", label: "自选排序") { store.route = .sorting }
                        .disabled(!store.storageHealthy)
                }
                IconButton(symbol: store.revealed ? "eye" : "eye.slash", label: store.revealed ? "隐藏名称和金额" : "显示名称和金额") { store.revealed.toggle() }
                IconButton(symbol: "xmark", label: "立即收起") { store.closePanel() }
            }.padding(.horizontal, 8).frame(height: 36)
            Divider()
            if store.showHoldings && !items.isEmpty {
                HStack(spacing: 10) {
                    summary("当日估算 · 元", store.summary.daily)
                    summary("浮动盈亏 · 元", store.summary.floating)
                }.padding(.horizontal, 12).padding(.vertical, 9)
                if !store.summary.missingSymbols.isEmpty || store.hasOldHoldings {
                    Text(!store.summary.missingSymbols.isEmpty ? "部分行情缺失，合计暂不可用" : "含旧行情，仅为历史估算")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.bottom, 6)
                }
                Divider()
            }
            if items.isEmpty {
                VStack(spacing: 9) {
                    Text(store.showHoldings ? "暂无持仓" : "暂无自选").font(.system(size: 12))
                    Button(store.showHoldings ? "查看自选" : "添加") {
                        if store.showHoldings { store.showHoldings = false } else { store.route = .add }
                    }.controlSize(.small).disabled(!store.storageHealthy)
                }.frame(maxWidth: .infinity).padding(.vertical, 26)
            } else {
                HStack(spacing: 6) {
                    Text(store.revealed ? "名称" : "代号").frame(maxWidth: .infinity, alignment: .leading)
                    Text(store.showHoldings ? "当日 · 元" : "涨跌幅").frame(width: 72, alignment: .trailing)
                    Text(store.showHoldings ? "浮动 · 元" : "涨跌 · 元").frame(width: 76, alignment: .trailing)
                }.font(.system(size: 10)).foregroundColor(.secondary).padding(.horizontal, 12).frame(height: 22)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in StockRow(store: store, item: item).id(item.id) }
                        }
                    }
                    .onChange(of: store.keyboardSelection) { id in
                        if let id { proxy.scrollTo(id) }
                    }
                    .onAppear { if let id = store.keyboardSelection { proxy.scrollTo(id) } }
                }.frame(height: min(CGFloat(items.count) * 32, 160))
            }
            Divider()
            HStack(spacing: 0) {
                Text(TradingSchedule.isOpen(store.now) ? (store.latestTime.map { UI.time($0) } ?? "等待行情") : store.marketLabel)
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                IconButton(symbol: "arrow.clockwise", label: store.isRefreshing ? "正在刷新行情" : "手动刷新行情") { Task { await store.refresh(manually: true) } }
                    .disabled(store.isRefreshing || store.state.items.isEmpty)
                IconButton(symbol: "plus", label: "添加股票或 ETF") { store.message = nil; store.route = .add }.disabled(!store.storageHealthy)
                IconButton(symbol: store.hasUnreadAlerts ? "bell.badge" : "bell", label: store.hasUnreadAlerts ? "查看提醒" : "提醒设置", active: store.hasUnreadAlerts) {
                    if store.hasUnreadAlerts { store.route = .inbox }
                    else if let item = store.state.items.first(where: { $0.id == store.state.pinnedSymbol }) ?? store.state.items.first { store.route = .edit(item.id, true) }
                }.disabled(store.state.items.isEmpty && !store.hasUnreadAlerts)
                IconButton(symbol: "slider.horizontal.3", label: "偏好设置") { store.message = nil; store.route = .settings }
            }.padding(.horizontal, 10).frame(height: 30)
        }
    }
    private func tab(_ title: String, holdings: Bool) -> some View {
        Button { store.showKeyboardList(holdings: holdings) } label: {
            Text(title).font(.system(size: 11)).padding(.horizontal, 7).padding(.vertical, 4)
                .background(store.showHoldings == holdings ? UI.surface : Color.clear).cornerRadius(4)
        }.buttonStyle(.plain).accessibilityAddTraits(store.showHoldings == holdings ? .isSelected : [])
    }
    private func summary(_ title: String, _ value: Decimal?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
            if store.revealed { SignedNumber(value: value, size: 14) }
            else { Text("••••").font(.system(size: 14)).accessibilityLabel("金额已隐藏") }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StockRow: View {
    @ObservedObject var store: AppStore
    let item: WatchItem
    private var quote: Quote? { store.quotes[item.id] }
    var body: some View {
        Button { store.keyboardSelection = item.id; store.message = nil; store.route = .edit(item.id, false) } label: {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Text(store.displayName(item)).lineLimit(1)
                    if store.state.pinnedSymbol == item.id { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundColor(.secondary) }
                    if store.isOld(item.id) { Text("旧").font(.system(size: 9)).foregroundColor(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                value(first: true).frame(width: 72, alignment: .trailing)
                value(first: false).frame(width: 76, alignment: .trailing)
            }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 32)
                .background(store.keyboardSelection == item.id ? Color.primary.opacity(0.08) : Color.clear)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(store.quoteLabel(item.id)).accessibilityLabel("编辑 " + store.displayName(item))
            .accessibilityAddTraits(store.keyboardSelection == item.id ? .isSelected : [])
    }
    @ViewBuilder private func value(first: Bool) -> some View {
        if store.showHoldings && !store.revealed { Text("••••").font(.system(size: 12)) }
        else {
            SignedNumber(value: quote.map { q in
                if store.showHoldings { return first ? item.holding.dailyProfit(q) : item.holding.floatingProfit(q) }
                return first ? q.percent : q.change
            }, suffix: !store.showHoldings && first ? "%" : "",
               digits: !store.showHoldings && !first ? item.symbol.priceFractionDigits : 2)
        }
    }
}

struct AlertInbox: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(store: store, title: "提醒", subtitle: "", showPrivacy: true)
            VStack(alignment: .leading, spacing: 10) {
                if store.previewDot { Text("静默提醒测试") }
                ForEach(store.state.unreadAlerts) { alert in
                    if let item = store.state.items.first(where: { $0.id == alert.symbol.rawValue }) {
                        Button { store.route = .edit(item.id, true) } label: {
                            HStack {
                                Text(store.displayName(item))
                                Spacer(minLength: 4)
                                if alert.kind.isHolding && !store.revealed {
                                    Text("••••").accessibilityLabel("持仓盈亏已隐藏")
                                } else {
                                    Text(UI.number(alert.value, signed: !alert.kind.isPrice,
                                                   digits: alert.kind.isPrice ? item.symbol.priceFractionDigits : 2)
                                         + (alert.kind.usesPercent ? "%" : " 元")).monospacedDigit()
                                }
                            }
                        }.buttonStyle(.plain)
                        Text(alert.day + " · " + alert.kind.label).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                if !store.hasUnreadAlerts { Text("暂无未读提醒").foregroundColor(.secondary) }
                Button("全部已读") { store.acknowledgeAlerts(); store.route = .home }.disabled(!store.hasUnreadAlerts || !store.storageHealthy)
            }.font(.system(size: 11)).padding(12)
        }
    }
}

struct WatchlistSortView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(store: store, title: "自选排序", subtitle: "")
            ForEach(Array(store.state.items.enumerated()), id: \.element.id) { index, item in
                HStack {
                    Text(store.displayName(item)).lineLimit(1)
                    Spacer(minLength: 4)
                    IconButton(symbol: "arrow.up", label: "上移 " + store.displayName(item)) { store.moveItem(item.id, offset: -1) }
                        .disabled(index == 0 || !store.storageHealthy)
                    IconButton(symbol: "arrow.down", label: "下移 " + store.displayName(item)) { store.moveItem(item.id, offset: 1) }
                        .disabled(index == store.state.items.count - 1 || !store.storageHealthy)
                }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 32)
            }
        }.padding(.bottom, 8)
    }
}
