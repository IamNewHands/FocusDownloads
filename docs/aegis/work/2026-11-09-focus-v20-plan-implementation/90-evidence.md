# Focus v20 执行证据

## 当前批次

- 用户在 2026-11-10 报告已安装 v20；导出失败、顶部闪透和侧滑残留是实际设备反馈，不是已通过的验收。
- 已推送修复来源 `a110b46b9f8863ef5bf0ee89039b486f5576aa4c`，本地 74 项 Python 检查通过。
- [CI42837951395](https://github.com/IamNewHands/FocusDownloads/actions/runs/42837951395) 原始 outcome：Foundation、WebKit、arm64 成功；备份、UIKit 失败。Python 在 CI 执行 73 项，另有本地 IPA 夹具缺失导致的 1 个跳过。
- 备份日志：真实宿主默认导出和根节点保留通过；在 `missing repository error still identifies category and read stage` 断言失败。
- UIKit 日志：在 `exactly one action runs after panel cleanup` 断言失败；尚未执行后续侧滑取消、嵌套页面和最终恢复断言。
- 总门禁正确失败，来源清单及上传跳过。本轮没有通过全部验证的 dylib 或新 IPA。
- 失败修正后的本地结果：76 项 Python 检查通过，`git diff --check` 通过；原生重跑尚待结果。新增诊断覆盖无 SQL/真实 SQL 两条访问路径，UIKit 原断言改为异步分阶段执行而非删除。

## 历史已确认

- 源 `67693ac7dd7c2d44eb1a1ed4e2f1e00bbf0ce157`：[CI42808122403](<https://github.com/IamNewHands/FocusDownloads/actions/runs/42808122403>) 总门禁/来源清单上传通过。真实 WKWebView 请求日志显示原 POST 一次到达，包含原 body 和 `fdm_nav=1`；没有替代 GET；真实成品文件确认。站点内容模式、页面JS和请求origin媒体决策夹具通过。
- 源 `6edfeef51baef87f14b56e5e0b7f8099ac066416`：[CI42810388400](<https://github.com/IamNewHands/FocusDownloads/actions/runs/42810388400>) 总门禁/来源清单通过。新增完整脚本metadata冲突/路径别名拒绝、原宿主SQL映射、真实 `.js` 原文读回、另一defaults实例/背景读者仅消费before、并发修改阻止marker且用户改动保留、rollbackPending新coordinator恢复前像全部通过。
- 当时 53 项本地 Python 包装/架构回归通过；这是历史数量，只说明包装与代码约束，不代表用户真机。
- 原 IPA SHA256 `377d37baf421ca90819a1a1624498be7776e553bb982a55f1a1173425ab9ae71`；原 PPBrowser SHA256 `6af11eb309cc7f2d75bd87ddaf4f6fb231305825a876678ae1414e2b7fcf424c`。
- 原 v19 IPA SHA256 `a39aee1077c9f52cbbe18a2bd393abc0978501e970c27373354d60e558f6a6b6`；图标owner与既有二进制补丁manifest未改变。

## 历史首个 v20 包

源 `1de62778369a7c9f24280db9eeb2832ff3c34bfe`：[CI42813107978](<https://github.com/IamNewHands/FocusDownloads/actions/runs/42813107978>) 该批次所有门禁与来源清单上传通过；图片真实GET一次、Cookie、成品与备份UI检查通过。下载artifact exit0。不是当前源码或本轮设备修复的验证结果。

包装命令 tools/build_focus.py exit0，输出独占新IPA；原SHA、库/源码来源、允许binarydiff、所有资源与ZIP读回核对通过。IPA `20794022` bytes / SHA256 `cb80a348b8a2d208f26a27d73ecbc5d6001651bc93d4d99d0333a8a8b2716289`；dylib `828464` bytes / SHA256 `54cbf7eb58b2057692a01b949556aa461f7d1aa389a99cd1ea79fbb00a2c3bc2`。最终Get-FileHash再次核对原包与v19包未改变。

## 明确未覆盖

- 用户已执行 v20 安装和设备测试，并报告上述故障；本轮修复后的真机复测尚未执行。
- iOS14.0–14.4 / 多旧系统、真正TCC弹窗、实际Reader/脚本引擎所有组合和VoiceOver体验不以夹具冒充已验收。
- Blob/MSE/DRM没有通用下载承诺；WebKit与ephemeral不保证匿名后台的等价跨启动恢复。
- 回滚故障在真实SQLite/defaults/files及宿主替身边界执行；不能声称所有真实设备进程杀死窗口均已测。

## 过程收口

2026-11-10 用户要求减少非必要测试/过度防御，不再扩大无关矩阵；当前仍必须修正已失败的必要检查并重新验证。源码 hook/静态证据、模拟器执行和真实设备结果分别陈述，不将历史交付改写为当前完成。
