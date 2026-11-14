import SwiftUI
import StockCore

struct IntradayPriceSummary: View {
    @ObservedObject var model: IntradayChartModel
    let symbol: StockSymbol
    let mode: IntradayMode
    let now: Date
    var body: some View {
        let series = model.displaySeries(for: symbol, mode: mode)
        let readout = model.readout(for: symbol, mode: mode)
        return StockPriceSummary(symbol: symbol, mode: mode, readout: readout,
            dateLabel: series.map { MarketClock.day($0.day) + (MarketClock.day($0.day) == MarketClock.day(now) ? " · 今日" : " · 历史") } ?? "等待行情",
            timeLabel: readout.map { selectionTime($0, now: now) } ?? "", isLoading: model.isLoading, refresh: model.refresh)
    }
}

/// One grid for all four detail tabs, including loading and missing-quote states.
struct StockPriceSummary: View {
    let symbol: StockSymbol
    let mode: IntradayMode
    let readout: IntradayReadout?
    let dateLabel: String
    var timeLabel = ""
    var isLoading = false
    var refresh: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, (geometry.size.width - 8) / 3)
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    priceColumn(mode == .line ? "当日最高价" : "区间最高价", value: readout?.high, width: width,
                                detail: mode == .line ? "昨收 " + number(readout?.previousClose) : "开 " + number(readout?.candle?.open))
                    priceColumn(mode == .line ? (readout?.isLatest == false ? "选中价格" : "当前价格") : "收盘价",
                                value: readout?.price, width: width, prominent: true,
                                detail: readout.map { UI.number($0.percent, signed: true) + "%" } ?? "—",
                                detailColor: IntradayPalette(colorScheme).color(readout?.percent ?? 0))
                    priceColumn(mode == .line ? "当日最低价" : "区间最低价", value: readout?.low, width: width,
                                detail: mode == .line ? "涨跌 " + number(readout?.change, signed: true) : "昨收 " + number(readout?.previousClose))
                }.frame(height: 57)
                HStack(spacing: 4) {
                    Text(dateLabel)
                    Spacer(minLength: 0)
                    Text(timeLabel)
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 16)
                        .opacity(isLoading ? 1 : 0).accessibilityHidden(!isLoading)
                    if let refresh {
                        IconButton(symbol: "arrow.clockwise", label: "刷新" + mode.title, action: refresh).disabled(isLoading)
                    } else {
                        Color.clear.frame(width: 22, height: 24).accessibilityHidden(true)
                    }
                }.font(.system(size: 9)).foregroundColor(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                    .frame(height: 24)
            }.padding(.top, 12)
        }.frame(height: 98).padding(.horizontal, 12)
    }

    private func number(_ value: Decimal?, signed: Bool = false) -> String {
        value.map { UI.number($0, signed: signed, digits: symbol.priceFractionDigits) } ?? "—"
    }

    private func priceColumn(_ title: String, value: Decimal?, width: CGFloat, prominent: Bool = false, detail: String, detailColor: Color = .secondary) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.system(size: 9)).foregroundColor(.secondary).frame(height: 11)
            Text(number(value)).font(.system(size: prominent ? 18 : 14, weight: prominent ? .medium : .regular))
                .frame(height: 22, alignment: .bottom)
                .accessibilityLabel(value.map { number($0) + " 元" } ?? "暂无数据")
            Text(detail).font(.system(size: prominent ? 11 : 9)).foregroundColor(detailColor).frame(height: 14)
        }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.65).frame(width: width, height: 57)
            .accessibilityElement(children: .combine)
    }
}

struct IntradayChartSection: View {
    @ObservedObject var model: IntradayChartModel
    let mode: IntradayMode
    let item: WatchItem
    let revealed: Bool
    let interval: Int
    let now: Date
    let editAlerts: () -> Void
    @ViewState private var showsLevels = true

    private struct Request: Hashable { let mode: IntradayMode; let refreshID: Int; let interval: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let series = model.displaySeries(for: item.symbol, mode: mode) {
                if series.isEmpty {
                    placeholder(mode == .line ? "暂无当日分时数据" : "暂无当日 5 分钟 K 线", loading: false)
                } else {
                    let levels = ChartPriceLevel.make(item: item, previousClose: series.previousClose, revealed: revealed)
                    IntradayPlot(series: series, mode: mode, levels: showsLevels ? levels : [], now: now, cursor: $model.cursor)
                    HStack(spacing: 2) {
                        let index = model.cursor.index(in: series, mode: mode) ?? 0
                        let count = mode == .line ? series.points.count : series.candles.count
                        IconButton(symbol: "chevron.left", label: "查看前一个数据点") { model.cursor.step(-1, in: series, mode: mode) }.disabled(index == 0)
                        IconButton(symbol: "chevron.right", label: "查看后一个数据点") { model.cursor.step(1, in: series, mode: mode) }.disabled(index >= count - 1)
                        Button("最新") { model.cursor = IntradayCursor() }
                            .buttonStyle(.plain).help("回到最新数据点")
                        Spacer(minLength: 0)
                        Toggle("价位线", isOn: $showsLevels).toggleStyle(.checkbox).disabled(levels.isEmpty)
                        Button("设置提醒", action: editAlerts).padding(.leading, 4)
                    }.font(.system(size: 10)).foregroundColor(.secondary).frame(height: 24)
                    if showsLevels && !levels.isEmpty { levelLegend(levels, series: series) }
                }
            } else {
                placeholder(model.isLoading ? "正在读取完整当日走势…" : "暂未取得走势数据", loading: model.isLoading)
            }
            if let error = model.error {
                Text((model.series?.isEmpty == false ? "更新失败，保留上次数据。" : "") + error)
                    .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("重试") { model.refresh() }.disabled(model.isLoading)
            }
        }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
            .task(id: Request(mode: mode, refreshID: model.refreshID, interval: interval)) {
                await model.monitor(item.symbol, mode: mode, interval: interval)
            }
            .onDisappear { model.cancel() }
    }

    private func placeholder(_ title: String, loading: Bool) -> some View {
        VStack(spacing: 10) {
            if loading { ProgressView().controlSize(.small) }
            Text(title).font(.system(size: 11)).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity).frame(height: 170)
    }

    private func levelLegend(_ levels: [ChartPriceLevel], series: IntradaySeries) -> some View {
        let domain = IntradayPlotDomain(series: series)
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 5) {
            ForEach(levels) { level in
                HStack(spacing: 4) {
                    let style = PriceLevelStyle(level.kind)
                    Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: 12, y: 0)) }
                        .stroke(style.color, style: StrokeStyle(lineWidth: 1, dash: style.dash)).frame(width: 12, height: 1)
                    let direction = level.price > domain.upper ? "↑" : level.price < domain.lower ? "↓" : ""
                    Text(direction + level.label + " " + UI.number(level.price, digits: item.symbol.priceFractionDigits))
                        .font(.system(size: 9)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                }.accessibilityElement(children: .combine)
            }
        }
    }
}

/// Price calculations stay Decimal; conversion to Double happens only at drawing time.
struct IntradayPlotDomain {
    let lower: Decimal
    let upper: Decimal
    init(series: IntradaySeries) {
        let values = series.points.map(\.price) + series.candles.flatMap { [$0.low, $0.high] } + [series.previousClose]
        let low = values.min() ?? series.previousClose, high = values.max() ?? series.previousClose
        let tick = series.symbol.isETF ? Decimal(string: "0.001")! : Decimal(string: "0.01")!
        let span = max(high - low, max(tick * 4, series.previousClose / 1_000))
        lower = max(tick / 10, low - span / 8)
        upper = high + span / 8
    }
    func fraction(_ price: Decimal) -> Double {
        NSDecimalNumber(decimal: (price - lower) / (upper - lower)).doubleValue
    }
}

private struct PriceLevelStyle {
    let color: Color
    let dash: [CGFloat]
    init(_ kind: ChartPriceLevel.Kind) {
        color = kind == .cost ? .secondary : .primary
        switch kind {
        case .priceAbove: dash = [5, 3]
        case .priceBelow: dash = [2, 3]
        case .percentUp: dash = [7, 2, 1, 2]
        case .percentDown: dash = [3, 2, 1, 2]
        case .cost: dash = [9, 3]
        }
    }
}

private struct IntradayPalette {
    let rising: Color
    let falling: Color
    init(_ scheme: ColorScheme) {
        rising = scheme == .dark ? Color(red: 1, green: 0.55, blue: 0.59) : Color(red: 0.72, green: 0.15, blue: 0.22)
        falling = scheme == .dark ? Color(red: 0.38, green: 0.84, blue: 0.69) : Color(red: 0.06, green: 0.43, blue: 0.32)
    }
    func color(_ change: Decimal) -> Color { change > 0 ? rising : change < 0 ? falling : .secondary }
}

struct IntradayPlot: View {
    let series: IntradaySeries
    let mode: IntradayMode
    let levels: [ChartPriceLevel]
    let now: Date
    @Binding var cursor: IntradayCursor
    @Environment(\.colorScheme) private var colorScheme

    private var count: Int { mode == .line ? series.points.count : series.candles.count }
    private var readout: IntradayReadout? { IntradayReadout(series: series, mode: mode, cursor: cursor) }
    private var selected: Int { readout?.index ?? 0 }
    private var domain: IntradayPlotDomain { IntradayPlotDomain(series: series) }
    private var palette: IntradayPalette { IntradayPalette(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                Canvas { context, size in draw(context: &context, size: size) }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): cursor.hoverTimestamp = nearest(location.x, width: geometry.size.width)
                        case .ended: cursor.hoverTimestamp = nil
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        cursor.selectedTimestamp = nearest(value.location.x, width: geometry.size.width)
                        cursor.hoverTimestamp = nil
                    })
            }.frame(height: 120)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(mode.title + "走势图，" + MarketClock.day(series.day))
                .accessibilityValue(readoutDescription)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: cursor.step(1, in: series, mode: mode)
                    case .decrement: cursor.step(-1, in: series, mode: mode)
                    @unknown default: break
                    }
                }
        }
    }

    private var readoutDescription: String {
        guard let readout else { return "暂无数据" }
        let time = selectionTime(readout, now: now)
        if let candle = readout.candle {
            return time + "，开盘 " + UI.input(candle.open) + "，最高 " + UI.input(candle.high)
                + "，最低 " + UI.input(candle.low) + "，收盘 " + UI.input(candle.close)
        }
        return time + "，价格 " + UI.number(readout.price, digits: series.symbol.priceFractionDigits)
            + " 元，涨跌幅 " + UI.number(readout.percent, signed: true) + "%"
    }

    private func position(_ index: Int) -> Double {
        let stamp = mode == .line ? series.points[index].timestamp : series.candles[index].timestamp
        return (TradingMinute.position(stamp) ?? 0) - (mode == .fiveMinute ? 2.5 : 0)
    }
    private func nearest(_ x: CGFloat, width: CGFloat) -> Date? {
        guard count > 0 else { return nil }
        let minute = Double(max(0, min(1, x / max(1, width - 48)))) * 240
        guard let index = (0..<count).min(by: { abs(position($0) - minute) < abs(position($1) - minute) }) else { return nil }
        return mode == .line ? series.points[index].timestamp : series.candles[index].timestamp
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let plot = CGRect(x: 0, y: 7, width: max(1, size.width - 48), height: size.height - 25)
        let scale = domain
        func x(_ minute: Double) -> CGFloat { plot.minX + CGFloat(minute / 240) * plot.width }
        func y(_ price: Decimal) -> CGFloat { plot.maxY - CGFloat(scale.fraction(price)) * plot.height }
        func line(_ from: CGPoint, _ to: CGPoint, color: Color, dash: [CGFloat] = [], width: CGFloat = 1) {
            let path = Path { $0.move(to: from); $0.addLine(to: to) }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dash))
        }
        for fraction in [Decimal(0), Decimal(string: "0.5")!, Decimal(1)] {
            let price = scale.lower + (scale.upper - scale.lower) * fraction, ordinate = y(price)
            line(CGPoint(x: plot.minX, y: ordinate), CGPoint(x: plot.maxX, y: ordinate), color: .secondary.opacity(0.2), dash: [1, 3])
            context.draw(Text(UI.number(price, digits: series.symbol.priceFractionDigits)).font(.system(size: 8)).monospacedDigit().foregroundColor(.secondary),
                         at: CGPoint(x: plot.maxX + 5, y: ordinate), anchor: .leading)
        }
        line(CGPoint(x: x(120), y: plot.minY), CGPoint(x: x(120), y: plot.maxY), color: .secondary.opacity(0.2), dash: [2, 3])
        let previousY = y(series.previousClose)
        line(CGPoint(x: plot.minX, y: previousY), CGPoint(x: plot.maxX, y: previousY), color: .secondary.opacity(0.6), dash: [2, 3])
        for level in levels where level.price >= scale.lower && level.price <= scale.upper {
            let style = PriceLevelStyle(level.kind), ordinate = y(level.price)
            line(CGPoint(x: plot.minX, y: ordinate), CGPoint(x: plot.maxX, y: ordinate), color: style.color.opacity(0.7), dash: style.dash)
        }
        if mode == .line {
            var path = Path()
            for (index, point) in series.points.enumerated() {
                let target = CGPoint(x: x(position(index)), y: y(point.price))
                if index == 0 || !TradingMinute.sameSession(series.points[index - 1].timestamp, point.timestamp)
                    || point.timestamp.timeIntervalSince(series.points[index - 1].timestamp) > 61 { path.move(to: target) }
                else { path.addLine(to: target) }
            }
            context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 1.35, lineJoin: .round))
            if let point = series.points.last {
                let center = CGPoint(x: x(position(count - 1)), y: y(point.price))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 1.8, y: center.y - 1.8, width: 3.6, height: 3.6)), with: .color(.primary))
            }
        } else {
            let width = max(1, plot.width / 48 * 0.65)
            for (index, candle) in series.candles.enumerated() {
                let abscissa = x(position(index)), color: Color = candle.close >= candle.open ? palette.rising : palette.falling
                line(CGPoint(x: abscissa, y: y(candle.high)), CGPoint(x: abscissa, y: y(max(candle.open, candle.close))), color: color)
                line(CGPoint(x: abscissa, y: y(min(candle.open, candle.close))), CGPoint(x: abscissa, y: y(candle.low)), color: color)
                let body = Path(CGRect(x: abscissa - width / 2, y: min(y(candle.open), y(candle.close)), width: width,
                                       height: max(1, abs(y(candle.close) - y(candle.open)))))
                if candle.close >= candle.open { context.stroke(body, with: .color(color), lineWidth: 1) }
                else { context.fill(body, with: .color(color)) }
            }
        }
        if count > 0 {
            let abscissa = x(position(selected)), price = mode == .line ? series.points[selected].price : series.candles[selected].close
            line(CGPoint(x: abscissa, y: plot.minY), CGPoint(x: abscissa, y: plot.maxY), color: .secondary, dash: [3, 3])
            let ordinate = y(price)
            context.fill(Path(ellipseIn: CGRect(x: abscissa - 2.5, y: ordinate - 2.5, width: 5, height: 5)), with: .color(.primary))
        }
        for (minute, label, anchor): (Double, String, UnitPoint) in [(0, "09:30", .leading), (120, "11:30 / 13:00", .center), (240, "15:00", .trailing)] {
            context.draw(Text(label).font(.system(size: 8)).monospacedDigit().foregroundColor(.secondary), at: CGPoint(x: x(minute), y: size.height - 3), anchor: anchor)
        }
    }
}

private func selectionTime(_ readout: IntradayReadout, now: Date) -> String {
    guard let candle = readout.candle else { return chartTime(readout.timestamp) + (readout.isLatest ? " · 最新" : " · 选中") }
    let direction = candle.close > candle.open ? "收涨" : candle.close < candle.open ? "收跌" : "平盘"
    return chartTime(candle.timestamp.addingTimeInterval(-300)) + "–" + chartTime(candle.timestamp)
        + " · " + (candle.timestamp > now ? "形成中" : direction)
}

private func chartTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = TradingMinute.calendar.timeZone; formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}
