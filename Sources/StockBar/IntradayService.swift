import Combine
import Foundation
import StockCore

protocol IntradayProviding {
    func fetch(_ symbol: StockSymbol, mode: IntradayMode) async throws -> IntradaySeries
}

enum IntradayServiceError: LocalizedError {
    case response, oversized
    var errorDescription: String? {
        switch self {
        case .response: return "走势服务暂时不可用，请检查网络后重试。"
        case .oversized: return "走势数据超出支持范围，请稍后重试。"
        }
    }
}

struct IntradayService: IntradayProviding {
    private let fetchData: (URLRequest) async throws -> (Data, URLResponse)
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()
    init() { fetchData = { try await Self.session.data(for: $0) } }
    init(fetchData: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.fetchData = fetchData
    }

    func fetch(_ symbol: StockSymbol, mode: IntradayMode) async throws -> IntradaySeries {
        var url: URLComponents
        switch mode {
        case .line:
            url = URLComponents(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query")!
            url.queryItems = [URLQueryItem(name: "code", value: symbol.rawValue)]
        case .fiveMinute:
            url = URLComponents(string: "https://ifzq.gtimg.cn/appstock/app/kline/mkline")!
            // Enough to include the entire current session even when opened late.
            // The parser selects the quote's date, never a rolling mix of days.
            url.queryItems = [URLQueryItem(name: "param", value: symbol.rawValue + ",m5,,96")]
        }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await fetchData(request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw IntradayServiceError.response }
        guard data.count <= 512_000 else { throw IntradayServiceError.oversized }
        switch mode {
        case .line: return try IntradayParser.minutes(data, symbol: symbol)
        case .fiveMinute: return try IntradayParser.candles(data, symbol: symbol)
        }
    }
}

/// A timestamp stays on the same point when a refresh fills gaps earlier in the day.
struct IntradayCursor: Equatable {
    var selectedTimestamp: Date?
    var hoverTimestamp: Date?

    func index(in series: IntradaySeries, mode: IntradayMode) -> Int? {
        let times = mode == .line ? series.points.map(\.timestamp) : series.candles.map(\.timestamp)
        guard !times.isEmpty else { return nil }
        guard let timestamp = hoverTimestamp ?? selectedTimestamp else { return times.count - 1 }
        return times.indices.min { abs(times[$0].timeIntervalSince(timestamp)) < abs(times[$1].timeIntervalSince(timestamp)) }
    }

    mutating func step(_ offset: Int, in series: IntradaySeries, mode: IntradayMode) {
        guard let index = index(in: series, mode: mode) else { return }
        let times = mode == .line ? series.points.map(\.timestamp) : series.candles.map(\.timestamp)
        selectedTimestamp = times[min(max(0, index + offset), times.count - 1)]
        hoverTimestamp = nil
    }
}

/// Shared by the price summary, crosshair and accessibility readout.
struct IntradayReadout {
    let index: Int
    let timestamp: Date
    let price: Decimal
    let previousClose: Decimal
    let high: Decimal?
    let low: Decimal?
    let candle: IntradayCandle?
    let isLatest: Bool
    var change: Decimal { price - previousClose }
    var percent: Decimal { change / previousClose * 100 }

    init(quote: Quote) {
        index = 0; timestamp = quote.timestamp; price = quote.last; previousClose = quote.previousClose
        high = quote.dayHigh; low = quote.dayLow; candle = nil; isLatest = true
    }

    init?(series: IntradaySeries, mode: IntradayMode, cursor: IntradayCursor) {
        guard let index = cursor.index(in: series, mode: mode) else { return nil }
        self.index = index; previousClose = series.previousClose
        if mode == .line {
            let point = series.points[index]
            timestamp = point.timestamp; price = point.price; candle = nil
            high = series.quote?.dayHigh; low = series.quote?.dayLow
            isLatest = index == series.points.count - 1
        } else {
            let bar = series.candles[index]
            timestamp = bar.timestamp; price = bar.close; candle = bar
            high = bar.high; low = bar.low
            isLatest = index == series.candles.count - 1
        }
    }
}

@MainActor final class IntradayChartModel: ObservableObject {
    @Published private(set) var series: IntradaySeries?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var activeMode: IntradayMode?
    @Published var cursor = IntradayCursor()
    @Published private(set) var refreshID = 0
    private let service: any IntradayProviding
    private let clock: () -> Date
    private var revision = 0
    private struct Key: Hashable { let symbol: StockSymbol; let mode: IntradayMode }
    private var cache: [Key: (IntradaySeries, Date)] = [:]

    init(service: any IntradayProviding = IntradayService(), clock: @escaping () -> Date = Date.init) {
        self.service = service; self.clock = clock
    }

    func displaySeries(for symbol: StockSymbol, mode: IntradayMode) -> IntradaySeries? {
        guard activeMode == mode, series?.symbol == symbol else { return nil }
        return series
    }

    func readout(for symbol: StockSymbol, mode: IntradayMode) -> IntradayReadout? {
        displaySeries(for: symbol, mode: mode).flatMap { IntradayReadout(series: $0, mode: mode, cursor: cursor) }
    }

    func latestQuote(for symbol: StockSymbol) -> Quote? {
        cache.filter { $0.key.symbol == symbol }.values.compactMap { $0.0.quote }.max { $0.timestamp < $1.timestamp }
    }

    func refresh() { refreshID &+= 1 }

    func load(_ symbol: StockSymbol, mode: IntradayMode) async {
        revision &+= 1
        let current = revision, key = Key(symbol: symbol, mode: mode)
        if activeMode != mode || series?.symbol != symbol || series?.day != cache[key]?.0.day { cursor = IntradayCursor() }
        activeMode = mode
        series = cache[key]?.0; fetchedAt = cache[key]?.1
        error = nil; isLoading = true
        defer { if revision == current { isLoading = false } }
        do {
            let found = try await service.fetch(symbol, mode: mode)
            try Task.checkCancellation()
            guard current == revision else { return }
            let now = clock()
            guard found.symbol == symbol, !found.previousClose.isNaN, found.previousClose > 0,
                  found.day <= TradingMinute.calendar.startOfDay(for: now),
                  found.quote.map({ $0.isValid && $0.symbol == symbol && $0.previousClose == found.previousClose
                      && TradingMinute.calendar.isDate($0.timestamp, inSameDayAs: found.day) }) ?? true,
                  found.lastTimestamp.map({ $0 <= now.addingTimeInterval(mode == .line ? 60 : 300) }) ?? true else {
                throw IntradayHistoryError.format
            }
            // Avoid replacing a fresh chart with an older CDN response.
            if let old = cache[key]?.0, old.day > found.day ||
                (old.day == found.day && (old.lastTimestamp ?? old.day) > (found.lastTimestamp ?? found.day)) {
                throw IntradayHistoryError.inconsistentDay
            }
            cache[key] = (found, now)
            if series?.day != found.day { cursor = IntradayCursor() }
            series = found; fetchedAt = now
        } catch {
            guard current == revision, !Task.isCancelled, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }

    /// Owned by SwiftUI's visible-view task: no history polling after the panel closes.
    func monitor(_ symbol: StockSymbol, mode: IntradayMode, interval: Int) async {
        while !Task.isCancelled {
            await load(symbol, mode: mode)
            guard !Task.isCancelled, let next = TradingSchedule.nextWake(after: clock(), interval: max(15, interval)) else { return }
            let delay = max(0.05, next.timeIntervalSince(clock()))
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
        }
    }

    func cancel() { revision &+= 1; isLoading = false; cursor.hoverTimestamp = nil }
}
