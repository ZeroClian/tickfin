# 参与贡献

欢迎通过 Issue 描述问题、提出精简功能建议，或提交 Pull Request。项目以小面板、低调显示和可靠的本地数据为优先，不计划变成完整交易终端。

## 开发

参见 README 的工具链和构建命令。新分支从 main 创建；保持修改范围清晰，避免无关格式化。不提交 .build、dist、真实持仓、凭证或个人调试日志。

- 使用 Decimal 计算价格、成本和盈亏，不改为浮点近似。
- 修改持久化结构必须保持旧数据兼容，增加迁移与损坏文件保护测试。
- 默认不发送系统通知；不得让隐藏状态下的视图、状态栏或提示泄露持仓。
- 提醒规则、网络失败、取消操作、日期与交易时段逻辑应有边界测试。
- UI 改动检查浅/深色原生布局，使用虚构持仓；验证窄面板及长说明，默认不保存验证截图。

提交前运行 `bash scripts/test.sh` 和 `bash scripts/build-app.sh`。UI 改动还应设置仓库外的 `TICKFIN_PREVIEW_DIR` 后运行 `bash scripts/render-preview.sh` 并实际点选检查；安装流程改动运行 `bash scripts/package-release.sh`。

PR 请说明问题、最终行为、验证结果及未覆盖的边界。自动化通过不等于系统横幅、菜单栏操作、不同 macOS 版本都已验证。

## 报告问题

提供应用版本、macOS 版本、芯片类型、复现步骤、预期和实际结果。行情问题可附证券代码与报价时间。请遮住持仓、账户、用户名，不要上传完整 state.json。敏感安全问题按 SECURITY.md 私下报告。

## 文档图片

原生预览使用固定示例行情、公开历史 fixture、隔离状态文件和通知替身，不访问个人持仓或发送推送。默认仅检查布局，不保存图片；先构建 release，再在自己指定的临时目录运行：

```bash
TICKFIN_PREVIEW_DIR=/path/to/project-temp/previews bash scripts/render-preview.sh
```

详情页布局改动还应运行 `TICKFIN_CHECK_SWITCHING=1 TICKFIN_PREVIEW_DIR=/path/to/project-temp/previews bash scripts/render-preview.sh`。此检查通过真实原生切换控件连续切换四个页签，逐帧断言面板高度及切换栏的位置、宽度和高度保持稳定，覆盖延迟加载、失败、空数据、浅深色、隐私显示和短屏；仅检查加载完成后的静态预览不足以发现切换时的跳动。

若构建时设置了 `TICKFIN_BUILD_ROOT`，预览时保持同一值。确需生成文档图片时另设 `TICKFIN_PREVIEW_IMAGES=1`；`TICKFIN_PREVIEW_EMIT=intraday-line-light,intraday-fiveMinute-dark` 可将指定图表以 base64 输出供内存预览，不写图片文件。检查图片后，仅将用于文档的最终 PNG 放入 `docs/screenshots/`；不要提交预览程序、缓存、个人测试数据或日志。Bark 图片展示完整设置组件，实际偏好页在固定高度面板中滚动。
