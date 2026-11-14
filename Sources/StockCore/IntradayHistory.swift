import Foundation

public enum IntradayMode: String, CaseIterable, Sendable {
    case line, fiveMinute
    public var title: String { self == .line ? "分时" : "5 分钟 K" }
}

public struct IntradayPoint: Equatable, Sendable {
    public let timestamp: Date
    public let price: Decimal
    public init(timestamp: Date, price: Decimal) { self.timestamp = timestamp; self.price = price }
}

public struct IntradayCandle: Equatable, Sendable {
    /// End of the five-minute interval; the last candle can still be forming.
    public let timestamp: Date
    public let open: Decimal
    public let close: Decimal
    public let high: Decimal
    public let low: Decimal
    public init(timestamp: Date, open: Decimal, close: Decimal, high: Decimal, low: Decimal) {
        self.timestamp = timestamp; self.open = open; self.close = close; self.high = high; self.low = low
    }
}

/// Display-only history. Never fed into the live quote cache or alert evaluator.
public struct IntradaySeries: Equatable, Sendable {
    public let symbol: StockSymbol
    public let day: Date
    public let previousClose: Decimal
    /// Quote returned with this history, validated against the same trading date.
    /// Kept for display of daily extremes; never inserted into the live quote cache.
    public let quote: Quote?
    public let points: [IntradayPoint]
    public let candles: [IntradayCandle]
    public var lastTimestamp: Date? { points.last?.timestamp ?? candles.last?.timestamp }
    public var lastPrice: Decimal? { points.last?.price ?? candles.last?.close }
    public var isEmpty: Bool { points.isEmpty && candles.isEmpty }
    public init(symbol: StockSymbol, day: Date, previousClose: Decimal, points: [IntradayPoint] = [], candles: [IntradayCandle] = [], quote: Quote? = nil) {
        self.symbol = symbol; self.day = TradingMinute.calendar.startOfDay(for: day)
        self.previousClose = previousClose; self.points = points; self.candles = candles; self.quote = quote
    }
}

public enum IntradayHistoryError: LocalizedError {
    case format, unavailable, inconsistentDay
    public var errorDescription: String? {
        switch self {
        case .format: return "走势数据格式异常，请稍后重试。"
        case .unavailable: return "暂未取得这只证券的走势数据，请稍后重试。"
        case .inconsistentDay: return "走势与参考价格的日期不一致，请刷新重试。"
        }
    }
}

/// A fixed 240-minute plot; lunch is a break, not 90 minutes of invented prices.
public enum TradingMinute {
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    public static func position(_ date: Date) -> Double? {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return nil }
        let value = hour * 60 + minute
        if (570...690).contains(value) { return Double(value - 570) }
        if (780...900).contains(value) { return Double(value - 780 + 120) }
        return nil
    }
    public static func sameSession(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
            && (calendar.component(.hour, from: lhs) < 12) == (calendar.component(.hour, from: rhs) < 12)
    }
}

public enum IntradayParser {
    public static func minutes(_ data: Data, symbol: StockSymbol) throws -> IntradaySeries {
        let (payload, quote) = try payload(data, symbol: symbol)
        guard let timeline = payload["data"] as? [String: Any], let date = timeline["date"] as? String,
              let day = timestamp(date, format: "yyyyMMdd"), let rows = timeline["data"] as? [String], rows.count <= 1_000 else {
            throw IntradayHistoryError.format
        }
        guard TradingMinute.calendar.isDate(day, inSameDayAs: quote.timestamp) else { throw IntradayHistoryError.inconsistentDay }
        var points: [Date: IntradayPoint] = [:]
        for row in rows {
            let fields = row.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 2, fields[0].count == 4,
                  let time = timestamp(date + fields[0], format: "yyyyMMddHHmm") else { throw IntradayHistoryError.format }
            // Some providers pad Shanghai/Shenzhen data through 15:30. Only plot the
            // continuous sessions, including their closing minute.
            guard TradingMinute.position(time) != nil else { continue }
            guard let price = price(fields[1]) else { throw IntradayHistoryError.format }
            points[time] = IntradayPoint(timestamp: time, price: price)
        }
        return IntradaySeries(symbol: symbol, day: day, previousClose: quote.previousClose,
                              points: points.values.sorted { $0.timestamp < $1.timestamp }, quote: quote)
    }

    public static func candles(_ data: Data, symbol: StockSymbol) throws -> IntradaySeries {
        let (payload, quote) = try payload(data, symbol: symbol)
        guard let rows = payload["m5"] as? [[Any]], rows.count <= 500 else { throw IntradayHistoryError.format }
        let day = TradingMinute.calendar.startOfDay(for: quote.timestamp)
        var candles: [Date: IntradayCandle] = [:]
        for row in rows {
            guard let stamp = row.first as? String, let time = timestamp(stamp, format: "yyyyMMddHHmm") else {
                throw IntradayHistoryError.format
            }
            // An opening request may include previous trading days. Never mix them
            // with today's candles or attach today's previous close to old bars.
            guard TradingMinute.calendar.isDate(time, inSameDayAs: day) else { continue }
            let components = TradingMinute.calendar.dateComponents([.hour, .minute], from: time)
            let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            guard ((575...690).contains(minute) || (785...900).contains(minute)), minute % 5 == 0 else { continue }
            guard row.count >= 5, let open = price(row[1]), let close = price(row[2]),
                  let high = price(row[3]), let low = price(row[4]),
                  low <= min(open, close), high >= max(open, close), high >= low else { throw IntradayHistoryError.format }
            candles[time] = IntradayCandle(timestamp: time, open: open, close: close, high: high, low: low)
        }
        return IntradaySeries(symbol: symbol, day: day, previousClose: quote.previousClose,
                              candles: candles.values.sorted { $0.timestamp < $1.timestamp }, quote: quote)
    }

    private static func payload(_ data: Data, symbol: StockSymbol) throws -> ([String: Any], Quote) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["code"] as? Int else { throw IntradayHistoryError.format }
        guard code == 0 else { throw IntradayHistoryError.unavailable }
        guard let symbols = root["data"] as? [String: Any], let payload = symbols[symbol.rawValue] as? [String: Any],
              let quotes = payload["qt"] as? [String: Any], let fields = quotes[symbol.rawValue] as? [String],
              let quote = QuoteParser.parse(fields: fields, symbol: symbol) else { throw IntradayHistoryError.unavailable }
        return (payload, quote)
    }

    private static func price(_ value: Any) -> Decimal? {
        guard let text = value as? String,
              text.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN, value > 0 else { return nil }
        return value
    }

    private static func timestamp(_ text: String, format: String) -> Date? {
        guard text.count == format.count, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = TradingMinute.calendar; formatter.timeZone = TradingMinute.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = format; formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
}

public struct ChartPriceLevel: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case priceAbove, priceBelow, percentUp, percentDown, cost }
    public let kind: Kind
    public let label: String
    public let price: Decimal
    public var id: String { kind.rawValue }

    public static func make(item: WatchItem, previousClose: Decimal, revealed: Bool) -> [ChartPriceLevel] {
        var levels: [ChartPriceLevel] = []
        func append(_ kind: Kind, _ label: String, _ price: Decimal) {
            guard !price.isNaN, price > 0 else { return }
            levels.append(ChartPriceLevel(kind: kind, label: label, price: price))
        }
        let rule = item.rule
        if (try? rule.validate()) != nil {
            if rule.price.aboveEnabled { append(.priceAbove, "涨到", rule.price.above) }
            if rule.price.belowEnabled { append(.priceBelow, "跌到", rule.price.below) }
            if !previousClose.isNaN, previousClose > 0 {
                if rule.upEnabled { append(.percentUp, "涨幅", previousClose * (1 + rule.upThreshold / 100)) }
                if rule.downEnabled { append(.percentDown, "跌幅", previousClose * (1 - rule.downThreshold / 100)) }
            }
        }
        if revealed, item.holding.quantity > 0, (try? item.holding.validate()) != nil { append(.cost, "成本", item.holding.averageCost) }
        return levels
    }
}
