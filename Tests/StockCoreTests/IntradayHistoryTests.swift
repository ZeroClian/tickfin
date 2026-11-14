import Foundation
import Testing
@testable import StockCore

private func historyFixture(_ label: String = "stock", candles: Bool = false) throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("docs/fixtures/intraday-20261113-\(label)-\(candles ? "m5" : "minute").json"))
}

private func changedHistory(_ data: Data, symbol: String = "sh600519", change: (inout [String: Any]) -> Void) throws -> Data {
    var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var symbols = try #require(root["data"] as? [String: Any])
    var payload = try #require(symbols[symbol] as? [String: Any])
    change(&payload)
    symbols[symbol] = payload; root["data"] = symbols
    return try JSONSerialization.data(withJSONObject: root)
}

private func historyDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@Test(arguments: [false, true]) func capturedHistoryBackfillsWholeDayForStockAndETF(etf: Bool) throws {
    let symbol = try StockSymbol(etf ? "159915" : "600519"), label = etf ? "etf" : "stock"
    let line = try IntradayParser.minutes(historyFixture(label), symbol: symbol)
    #expect(line.points.count == 242)
    #expect(line.points.first?.timestamp == historyDate("2026-11-13T01:30:00Z"))
    #expect(line.points.last?.timestamp == historyDate("2026-11-13T07:00:00Z"))
    #expect(line.lastPrice == Decimal(string: etf ? "2.442" : "1435.26"))
    #expect(line.quote?.dayHigh == Decimal(string: etf ? "2.546" : "1437.69"))
    #expect(line.quote?.dayLow == Decimal(string: etf ? "2.432" : "1394.00"))
    #expect(line.quote.map { TradingMinute.calendar.isDate($0.timestamp, inSameDayAs: line.day) } == true)
    #expect(line.points.allSatisfy { TradingMinute.position($0.timestamp) != nil })
    let candles = try IntradayParser.candles(historyFixture(label, candles: true), symbol: symbol)
    #expect(candles.candles.count == 48)
    #expect(candles.candles.first?.timestamp == historyDate("2026-11-13T01:35:00Z"))
    #expect(candles.candles.last?.timestamp == historyDate("2026-11-13T07:00:00Z"))
    #expect(candles.lastPrice == line.lastPrice)
    #expect(candles.day == line.day && candles.previousClose == line.previousClose)
    #expect(candles.quote?.dayHigh == line.quote?.dayHigh && candles.quote?.dayLow == line.quote?.dayLow)
    if etf {
        #expect(candles.candles.first?.low == Decimal(string: "2.503"))
        #expect(line.points.first?.price == Decimal(string: "2.533"))
    }
}

@Test func minutesAreSortedDeduplicatedAndExcludeLunchAndAfterHours() throws {
    let data = try changedHistory(historyFixture()) { payload in
        payload["data"] = ["date": "20261113", "data": ["1301 102 1", "0930 100 1", "1130 101 1", "1300 101 1", "1530 999 1", "1200 888 1", "0930 100.25 1"]]
    }
    let series = try IntradayParser.minutes(data, symbol: StockSymbol("600519"))
    #expect(series.points.map(\.price) == [Decimal(string: "100.25")!, 101, 101, 102])
    #expect(!TradingMinute.sameSession(series.points[1].timestamp, series.points[2].timestamp))
}

@Test(arguments: ["NaN", "Infinity", "12oops", "0", "-1"]) func corruptIntradayPricesAreNotRendered(text: String) throws {
    let data = try changedHistory(historyFixture()) { payload in
        payload["data"] = ["date": "20261113", "data": ["0930 \(text) 1"]]
    }
    #expect(throws: (any Error).self) { try IntradayParser.minutes(data, symbol: StockSymbol("600519")) }
}

@Test func historiesValidateSecurityIdentityAndReferenceDate() throws {
    let symbol = try StockSymbol("600519")
    for (field, value) in [(2, "000001"), (61, "ETF"), (31, "9999")] {
        let data = try changedHistory(historyFixture()) { payload in
            var quotes = payload["qt"] as! [String: Any], fields = quotes[symbol.rawValue] as! [String]
            fields[field] = value; quotes[symbol.rawValue] = fields; payload["qt"] = quotes
        }
        #expect(throws: (any Error).self) { try IntradayParser.minutes(data, symbol: symbol) }
    }
    for day in ["20261112", "20260230", "20261301"] {
        let data = try changedHistory(historyFixture()) { $0["data"] = ["date": day, "data": ["0930 100 1"]] }
        #expect(throws: (any Error).self) { try IntradayParser.minutes(data, symbol: symbol) }
    }
    #expect(throws: (any Error).self) { try IntradayParser.minutes(historyFixture(), symbol: StockSymbol("000001")) }
}

@Test func fiveMinuteBarsKeepOnlyReferenceDayAndValidateOHLC() throws {
    let symbol = try StockSymbol("600519")
    let data = try changedHistory(historyFixture(candles: true)) { payload in
        payload["m5"] = [["202611121500", "9", "9", "9", "9"], ["202611130935", "100", "101", "102", "99"],
                         ["202611131300", "999", "999", "999", "999"], ["202611131530", "999", "999", "999", "999"]]
    }
    let series = try IntradayParser.candles(data, symbol: symbol)
    #expect(series.candles.count == 1)
    #expect(series.candles.first?.open == 100 && series.candles.first?.close == 101)
    for row in [["202611130935", "100", "101", "99", "98"], ["202611130935", "100", "101", "102", "101"],
                ["202611130935", "100", "NaN", "102", "99"]] {
        let invalid = try changedHistory(data) { $0["m5"] = [row] }
        #expect(throws: (any Error).self) { try IntradayParser.candles(invalid, symbol: symbol) }
    }
}

@Test func preopenCandlesDoNotRelabelPreviousDayAsToday() throws {
    let symbol = try StockSymbol("600519")
    let data = try changedHistory(historyFixture(candles: true)) { payload in
        var quotes = payload["qt"] as! [String: Any], fields = quotes[symbol.rawValue] as! [String]
        fields[30] = "20261116092500"; quotes[symbol.rawValue] = fields; payload["qt"] = quotes
    }
    let series = try IntradayParser.candles(data, symbol: symbol)
    #expect(MarketClock.day(series.day) == "2026-11-16")
    #expect(series.isEmpty)
}

@Test func tradingPlotCompressesLunchAndIncludesSessionEnds() {
    let positions: [(String, Double?)] = [("01:30", 0), ("03:30", 120), ("04:00", nil), ("05:00", 120), ("07:00", 240), ("07:01", nil)]
    for (time, position) in positions {
        #expect(TradingMinute.position(historyDate("2026-11-13T" + time + ":00Z")) == position)
    }
}

@Test func alertPriceLevelsUseDecimalAndHideCostUntilRevealed() throws {
    var rule = AlertRule(upEnabled: true, downEnabled: true)
    rule.price.aboveEnabled = true; rule.price.above = 110
    rule.price.belowEnabled = true; rule.price.below = 95
    var item = WatchItem(symbol: try StockSymbol("159915"), name: "测试ETF", holding: Holding(quantity: 100, averageCost: 99), rule: rule)
    let hidden = ChartPriceLevel.make(item: item, previousClose: 100, revealed: false)
    #expect(hidden.map(\.price) == [110, 95, 103, 98])
    #expect(!hidden.contains { $0.kind == .cost })
    #expect(ChartPriceLevel.make(item: item, previousClose: 100, revealed: true).last?.price == 99)
    item.holding.quantity = 0
    #expect(!ChartPriceLevel.make(item: item, previousClose: 100, revealed: true).contains { $0.kind == .cost })
    item.rule.downThreshold = 120
    #expect(!ChartPriceLevel.make(item: item, previousClose: 100, revealed: false).contains { $0.kind == .percentDown })
}
