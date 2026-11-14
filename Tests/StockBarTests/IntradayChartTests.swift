import Foundation
import Testing
import StockCore
@testable import StockBar

private func chartDate(_ text: String = "2026-11-14T02:00:00Z") -> Date { ISO8601DateFormatter().date(from: text)! }
private func chartSeries(_ symbol: String = "600519", mode: IntradayMode = .line, day: String = "2026-11-13") throws -> IntradaySeries {
    let stamp = chartDate(day + "T07:00:00Z")
    return IntradaySeries(symbol: try StockSymbol(symbol), day: stamp, previousClose: 100,
        points: mode == .line ? [IntradayPoint(timestamp: stamp, price: 101)] : [],
        candles: mode == .fiveMinute ? [IntradayCandle(timestamp: stamp, open: 100, close: 101, high: 102, low: 99)] : [])
}

private actor PendingHistories: IntradayProviding {
    private var pending: [IntradayMode: CheckedContinuation<IntradaySeries, Error>] = [:]
    func fetch(_ symbol: StockSymbol, mode: IntradayMode) async throws -> IntradaySeries {
        try await withCheckedThrowingContinuation { pending[mode] = $0 }
    }
    func has(_ mode: IntradayMode) -> Bool { pending[mode] != nil }
    func finish(_ mode: IntradayMode, with value: IntradaySeries) { pending.removeValue(forKey: mode)?.resume(returning: value) }
}

private actor ScriptedHistories: IntradayProviding {
    var replies: [Result<IntradaySeries, IntradayHistoryError>]
    private(set) var calls = 0
    init(_ replies: [Result<IntradaySeries, IntradayHistoryError>]) { self.replies = replies }
    func fetch(_ symbol: StockSymbol, mode: IntradayMode) async throws -> IntradaySeries {
        calls += 1
        guard !replies.isEmpty else { throw IntradayHistoryError.unavailable }
        return try replies.removeFirst().get()
    }
}

@MainActor private func awaitChart(_ condition: () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    throw IntradayHistoryError.unavailable
}

@MainActor @Test func switchingChartModeDiscardsLatePreviousResponse() async throws {
    let service = PendingHistories(), symbol = try StockSymbol("600519")
    let model = IntradayChartModel(service: service, clock: { chartDate() })
    let line = Task { await model.load(symbol, mode: .line) }
    try await awaitChart { await service.has(.line) }
    let candles = Task { await model.load(symbol, mode: .fiveMinute) }
    try await awaitChart { await service.has(.fiveMinute) }
    let expected = try chartSeries(mode: .fiveMinute)
    await service.finish(.fiveMinute, with: expected); await candles.value
    await service.finish(.line, with: try chartSeries()); await line.value
    #expect(model.activeMode == .fiveMinute && model.series == expected)
    #expect(!model.isLoading && model.error == nil)
}

@MainActor @Test func closingChartDiscardsUncooperativeNetworkCallback() async throws {
    let service = PendingHistories(), symbol = try StockSymbol("600519")
    let model = IntradayChartModel(service: service, clock: { chartDate() })
    let request = Task { await model.load(symbol, mode: .line) }
    try await awaitChart { await service.has(.line) }
    model.cancel(); request.cancel()
    await service.finish(.line, with: try chartSeries()); await request.value
    #expect(model.series == nil && !model.isLoading && model.error == nil)
}

@MainActor @Test func refreshFailureKeepsLastChartAndRetryRecovers() async throws {
    let expected = try chartSeries(), symbol = expected.symbol
    let service = ScriptedHistories([.success(expected), .failure(.unavailable), .success(expected)])
    let model = IntradayChartModel(service: service, clock: { chartDate() })
    await model.load(symbol, mode: .line)
    await model.load(symbol, mode: .line)
    #expect(model.series == expected && model.error != nil && !model.isLoading)
    await model.load(symbol, mode: .line)
    #expect(model.series == expected && model.error == nil)
}

@MainActor @Test func chartRejectsWrongSymbolFutureDataAndCDNRegression() async throws {
    let expected = try chartSeries(), symbol = expected.symbol
    let service = ScriptedHistories([.success(expected), .success(try chartSeries("000001")),
                                    .success(try chartSeries(day: "2026-11-16")), .success(try chartSeries(day: "2026-11-12"))])
    let model = IntradayChartModel(service: service, clock: { chartDate() })
    await model.load(symbol, mode: .line)
    for _ in 0..<3 {
        await model.load(symbol, mode: .line)
        #expect(model.series == expected && model.error != nil)
    }
}

@MainActor @Test func closingChartCancelsScheduledPolling() async throws {
    let expected = try chartSeries()
    let service = ScriptedHistories([.success(expected)])
    let model = IntradayChartModel(service: service, clock: { chartDate("2026-11-13T07:05:00Z") })
    let task = Task { await model.monitor(expected.symbol, mode: .line, interval: 15) }
    try await awaitChart { await service.calls == 1 && !model.isLoading }
    task.cancel(); await task.value
    #expect(await service.calls == 1)
    #expect(model.series == expected)
}

@MainActor @Test func flatETFPlotHasFiniteReadablePriceDomain() throws {
    let stamp = chartDate("2026-11-13T07:00:00Z"), price = Decimal(string: "2.442")!
    let series = IntradaySeries(symbol: try StockSymbol("159915"), day: stamp, previousClose: price,
                                points: [IntradayPoint(timestamp: stamp, price: price)])
    let domain = IntradayPlotDomain(series: series)
    #expect(domain.lower > 0 && domain.lower < price && domain.upper > price)
    #expect(domain.fraction(price).isFinite && (0...1).contains(domain.fraction(price)))
}

@MainActor @Test(arguments: [IntradayMode.line, .fiveMinute]) func chartServiceRequestsHistoryWithoutAccountData(mode: IntradayMode) async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("docs/fixtures/intraday-20261113-stock-\(mode == .line ? "minute" : "m5").json"))
    var captured: URLRequest?
    let service = IntradayService { request in
        captured = request
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let series = try await service.fetch(StockSymbol("600519"), mode: mode)
    #expect(!series.isEmpty)
    let request = try #require(captured), url = try #require(request.url)
    #expect(url.scheme == "https" && request.httpBody == nil)
    let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.count == 1)
    #expect(query[0].value == (mode == .line ? "sh600519" : "sh600519,m5,,96"))
}

@Test(arguments: [0, 1, 2]) func chartServiceRejectsHTTPAndInvalidPayloads(kind: Int) async throws {
    let service = IntradayService { request in
        let data = kind == 2 ? Data(repeating: 32, count: 512_001) : Data("<html>failure</html>".utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: kind == 0 ? 503 : 200, httpVersion: nil, headerFields: nil)!)
    }
    await #expect(throws: (any Error).self) { try await service.fetch(StockSymbol("600519"), mode: .line) }
}

@MainActor @Test(arguments: [IntradayMode.line, .fiveMinute]) func chartHeaderAndCrosshairUseTheSameSelectedPoint(mode: IntradayMode) async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("docs/fixtures/intraday-20261113-etf-\(mode == .line ? "minute" : "m5").json"))
    let symbol = try StockSymbol("159915")
    let series = try mode == .line ? IntradayParser.minutes(data, symbol: symbol) : IntradayParser.candles(data, symbol: symbol)
    let model = IntradayChartModel(service: ScriptedHistories([.success(series)]), clock: { chartDate() })
    await model.load(symbol, mode: mode)
    let latest = try #require(model.readout(for: symbol, mode: mode))
    #expect(latest.price == Decimal(string: "2.442") && latest.timestamp == series.lastTimestamp && latest.isLatest)
    #expect(UI.number(latest.price, digits: symbol.priceFractionDigits) == "2.442")
    #expect(model.latestQuote(for: symbol) == series.quote)

    let stamp = mode == .line ? series.points[12].timestamp : series.candles[12].timestamp
    model.cursor.selectedTimestamp = stamp
    let selected = try #require(model.readout(for: symbol, mode: mode))
    #expect(selected.timestamp == stamp && selected.index == 12 && !selected.isLatest)
    #expect(selected.percent == (selected.price - series.previousClose) / series.previousClose * 100)
    if mode == .line {
        #expect(selected.price == series.points[12].price && selected.candle == nil)
        #expect(selected.high == Decimal(string: "2.546") && selected.low == Decimal(string: "2.432"))
    } else {
        let bar = series.candles[12]
        #expect(selected.candle == bar && selected.price == bar.close && selected.high == bar.high && selected.low == bar.low)
    }
    model.cursor.hoverTimestamp = series.lastTimestamp
    #expect(model.readout(for: symbol, mode: mode)?.price == latest.price)
    model.cursor.hoverTimestamp = nil
    #expect(model.readout(for: symbol, mode: mode)?.timestamp == stamp)
    model.cursor.step(-1000, in: series, mode: mode)
    #expect(model.readout(for: symbol, mode: mode)?.index == 0)
    model.cursor.step(1000, in: series, mode: mode)
    #expect(model.readout(for: symbol, mode: mode)?.price == latest.price)
    model.cursor = IntradayCursor()
    #expect(model.readout(for: symbol, mode: mode)?.isLatest == true)
}

@MainActor @Test func selectedTimestampSurvivesRefreshBackfillAndLatestFollowsNewPoints() async throws {
    let symbol = try StockSymbol("600519"), first = chartDate("2026-11-13T01:30:00Z")
    func series(_ offsets: [Int]) -> IntradaySeries {
        IntradaySeries(symbol: symbol, day: first, previousClose: 100,
            points: offsets.map { IntradayPoint(timestamp: first.addingTimeInterval(Double($0 * 60)), price: Decimal(100 + $0)) })
    }
    let model = IntradayChartModel(service: ScriptedHistories([.success(series([0, 2])), .success(series([0, 1, 2, 3])), .success(series([0, 1, 2, 3, 4]))]), clock: { chartDate() })
    await model.load(symbol, mode: .line)
    let selectedTime = first.addingTimeInterval(120)
    model.cursor.selectedTimestamp = selectedTime
    await model.load(symbol, mode: .line)
    let selected = try #require(model.readout(for: symbol, mode: .line))
    #expect(selected.timestamp == selectedTime && selected.index == 2 && selected.price == 102 && !selected.isLatest)
    model.cursor = IntradayCursor()
    await model.load(symbol, mode: .line)
    #expect(model.readout(for: symbol, mode: .line)?.price == 104)
    #expect(model.readout(for: symbol, mode: .line)?.isLatest == true)
}

@MainActor @Test func switchingModeOrTradingDayResetsSelectionAndDoesNotShowOldModeNumbers() async throws {
    let line = try chartSeries(), candles = try chartSeries(mode: .fiveMinute), nextDay = try chartSeries(day: "2026-11-16")
    let model = IntradayChartModel(service: ScriptedHistories([.success(line), .failure(.unavailable), .success(candles), .success(line), .success(nextDay)]), clock: { chartDate("2026-11-16T08:00:00Z") })
    await model.load(line.symbol, mode: .line)
    model.cursor.selectedTimestamp = line.lastTimestamp
    model.cursor.hoverTimestamp = line.lastTimestamp
    #expect(model.readout(for: line.symbol, mode: .fiveMinute) == nil)
    await model.load(line.symbol, mode: .fiveMinute)
    #expect(model.cursor == IntradayCursor())
    #expect(model.readout(for: line.symbol, mode: .fiveMinute) == nil && model.readout(for: line.symbol, mode: .line) == nil)
    await model.load(line.symbol, mode: .fiveMinute)
    #expect(model.readout(for: line.symbol, mode: .fiveMinute)?.candle == candles.candles.last)
    await model.load(line.symbol, mode: .line)
    model.cursor.selectedTimestamp = line.lastTimestamp
    model.cursor.hoverTimestamp = line.lastTimestamp
    await model.load(line.symbol, mode: .line)
    #expect(model.cursor == IntradayCursor() && model.displaySeries(for: line.symbol, mode: .line)?.day == nextDay.day)
    #expect(model.readout(for: try StockSymbol("000001"), mode: .line) == nil)
}

@MainActor @Test func historyQuoteFromAnotherDayCannotReplaceHeader() async throws {
    let good = try chartSeries(), symbol = good.symbol
    let oldQuote = Quote(symbol: symbol, name: "测试", last: 101, previousClose: 100, percent: 1, timestamp: chartDate("2026-11-10T07:00:00Z"), dayHigh: 110, dayLow: 90)
    let inconsistent = IntradaySeries(symbol: symbol, day: good.day, previousClose: good.previousClose, points: good.points, quote: oldQuote)
    let model = IntradayChartModel(service: ScriptedHistories([.success(good), .success(inconsistent)]), clock: { chartDate() })
    await model.load(symbol, mode: .line)
    await model.load(symbol, mode: .line)
    #expect(model.error != nil && model.series == good && model.latestQuote(for: symbol) == nil)
    #expect(model.readout(for: symbol, mode: .line)?.high == nil)
}
