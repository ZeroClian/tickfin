import SwiftUI

enum UsageGuideTopic: String, CaseIterable, Identifiable {
    case watchlist, charts, holdings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .watchlist: return "自选与排序"
        case .charts: return "分时、K 线与价位线"
        case .holdings: return "持仓与盈亏计算"
        }
    }
    var text: String {
        switch self {
        case .watchlist:
            return "支持沪深北 A 股及沪深场内 ETF。添加时输入六位代码或拼音首字母，在搜索结果中点击＋。\n\n自选排序页的上下移动会立即保存，代号保持不变；持仓列表沿用自选顺序。"
        case .charts:
            return "分时按分钟显示当天行情，5 分钟 K 包含对应区间的开、高、低、收。午休分段，休市显示最近可用交易日，日期和时间以上方读数为准。\n\n悬停或点击图表时，上方数字同步变化。左右按钮逐点浏览，“最新”恢复跟随末点；刷新会保留已选时间。\n\n红色空心 K 表示收涨，绿色实心 K 表示收跌；区间尚未结束时标记“形成中”。部分证券可能没有分钟 K 数据，可改看分时。\n\n价位线对应已保存的到价提醒、按昨收换算的涨跌幅阈值，以及显示持仓时的成本。图例中的 ↑ / ↓ 表示价位在图区上方 / 下方。"
        case .holdings:
            return "当日估算＝（现价 − 昨收价）× 持仓数量。\n浮动盈亏＝（现价 − 平均成本）× 持仓数量。\n\n股票数量按股，ETF 按份；股票价格保留两位小数，ETF 保留三位。列表中的涨跌额为每股或每份的价格变化。\n\n上述结果不计日内交易、已卖出收益或分红。数量填 0 并保存可清空持仓；“清空持仓”确认后立即保存，保留自选和提醒，不影响券商账户。"
        }
    }
}

struct UsageGuideView: View {
    @ViewState private var expanded: Set<UsageGuideTopic>
    init(expandAll: Bool = false) {
        _expanded = ViewState(initialValue: expandAll ? Set(UsageGuideTopic.allCases) : [])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(UsageGuideTopic.allCases) { topic in
                DisclosureGroup(topic.title, isExpanded: Binding(
                    get: { expanded.contains(topic) },
                    set: { if $0 { expanded.insert(topic) } else { expanded.remove(topic) } }
                )) {
                    Text(topic.text).font(.system(size: 10)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
                }
            }
        }
    }
}
