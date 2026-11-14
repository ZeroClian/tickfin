# 公开行情回归数据

`intraday-20261113-{stock,etf}-{minute,m5}.json` 于 2026-11-14 读取腾讯公开行情服务，行情对应 2026-11-13。股票为 `sh600519`，ETF 为 `sz159915`；文件不含账户、持仓或凭证。

- 分时：`https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=证券代码`。
- 5 分钟 K：`https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=证券代码,m5,,96`。

保留原始响应，测试验证盘中 242 个分钟时间戳、当天 48 根 K 线、ETF 三位小数、午休分段，以及对响应中其他交易日 / 15:00 后数据的过滤。行情服务在交易中、休市、停牌或对不同证券的覆盖可能不同；这些 fixture 不是持续可用性的保证。
