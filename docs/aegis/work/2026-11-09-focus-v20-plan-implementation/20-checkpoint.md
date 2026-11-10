# Focus v20 实施与交付 — checkpoint

## 当前状态

截至 2026-11-10，用户已安装并测试 v20，反馈备份导出失败、下载管理和网站规则进入时顶部闪透、工具栏下载页侧滑返回残留。原①④⑤功能已有历史交付，但本轮设备回归尚未验收，不能声明整体完成。

- 已推送设备修复来源：`a110b46b9f8863ef5bf0ee89039b486f5576aa4c`。本地 74 项 Python 检查通过；不是历史包的 `1de6277` 来源。
- CI42837951395 失败：Foundation、WebKit、arm64 通过；备份错误诊断测试、UIKit 菜单关闭回调测试失败。`continue-on-error` 使步骤界面显示成功，总门禁仍按原始 outcome 正确阻止发布。
- 两处失败已本地修正：导出保留回调错误，UIKit 测试跨真实主队列轮次执行；76 项 Python 检查通过。原生重跑仍待结果。
- 本轮来源清单和产物上传尚未通过，没有包含本轮修复的新 IPA；不扩大无关测试矩阵。
- 旧菜单修复包 `D:\GitHub_Clone\Focus_2.9.7_patched_v20_fix_dcab80e.ipa` 对应 `dcab80e46dd498a42d023aa795caff2f4d326dc5`，不包含 `a110b46` 的导出与转场修改。

## 历史批次

以下结果只证明列出的来源提交和对应夹具，不代表当前源码或用户真机回归已通过。
- `67693ac7dd7c2d44eb1a1ed4e2f1e00bbf0ce157` / CI42808122403：所有门禁通过。真实 WKWebView 的原 POST 恰好一次，Cookie/body 到达服务器，成品确认；内容模式/页面JS/请求origin权限夹具通过。
- `6edfeef51baef87f14b56e5e0b7f8099ac066416` / CI42810388400：所有门禁通过。包含完整metadata冲突、文件名别名拒绝、真实 SQLite 与 .js 原文、读取屏障/并发写、rollbackPending 新owner恢复前像。备份类别选择UI完成并编译。
- `8c26d2624f4d42fe3831795b1b40db85f8da4270` / CI42811920193：图片新GET到达但 Cookie 为空，门禁正确阻止产物；源页测试只等 URL，日志没有源页 GET，不能证明生产API不带Cookie。
- `1de6277` / CI42813107978：总门禁与来源清单上传通过；真实原POST、本页图片GET/Cookie/成品、备份类别选择、原生回归均通过。
- 已打包 `D:\GitHub_Clone\Focus_2.9.7_patched_v20.ipa`（20794022 bytes），SHA256 `cb80a348b8a2d208f26a27d73ecbc5d6001651bc93d4d99d0333a8a8b2716289`。打包器exit0，库/source/允许binarydiff/资源/ZIP读回通过。
- dylib位于 `_artifacts/focusdm/v20-1de62778369a7c9f24280db9eeb2832ff3c34bfe/FocusDM.dylib`（828464 bytes），SHA256 `54cbf7eb58b2057692a01b949556aa461f7d1aa389a99cd1ea79fbb00a2c3bc2`；同目录有provenance与安装说明。原IPA、v19 IPA最终hash再次确认未改变。

## 已实现与保存边界

- FDMEngine 唯一下载状态owner，FDMWebKitDownloads执行；原 POST 使用 didBecomeDownload，不复制GET；图片显式新选择才调用startDownloadUsingRequest。
- FDMSitePolicyStore唯一策略owner；精确scheme/host/port、main导航preferences、脚本registry、媒体request/frame origin、临时关闭；TCC/TLS不改变。
- 备份六类别读取原宿主SQL/defaults/policy；scripts opt-in；不可变差异计划且实际提交不重新preview；本地前像＋prepared/rollbackPending/committed marker、短期读屏障；回滚失败不正常加载混合配置。
- FDMIcons/FDMIconDiagnostics 与既有binary补丁manifest未改变；原IPA与v19 IPA hash已核对。

## 下一动作

提交两处本地修正并重跑完整原生 CI。只有总门禁和来源清单通过后才打包独占新 IPA；之后由用户沿用当前 bundle ID/签名方案在 LCSign 重签覆盖安装，不先卸载。实际导出、顶部闪透、一次侧滑返回及取消侧滑仍需真机复测。

## 证据与纠偏

先前“第5步基本完成/只差编译”在2026-11-09接续时与源码矛盾，已撤回；后续真实CI成功只证明其对应提交和场景，不改写当时错误声明。任何未覆盖真机不得标PASS。

TDD off；不强制RED/GREEN。历史 IPA 交付与本轮修复验收分开记录；不把旧 CI 或本地源码检查当当前原生、真机结果。未跟踪探针和旧文件继续保留。本轮详细状态见 [设备回归记录](../../../focus-v20-device-regressions-2026-11-10.md)。
