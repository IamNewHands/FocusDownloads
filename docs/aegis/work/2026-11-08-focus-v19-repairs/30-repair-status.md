# Focus v19 逐项修复状态

基线：源码 `3e566c4569e2866cd991097494ca1f3bbb4f64d7`；报告问题编号保持原义。用户已批准 main 推送、macOS CI、下载新库并生成全新未重签 IPA，不覆盖旧包、不代签安装。

## 代码修复映射（候选，原生待 CI）

| 报告项 | 实现 owner 与处理 | 当前验证边界 |
|---|---|---|
| I1 | FDMIcons 精确映射4类页面/位图/文字，成功应用与命中分开 | stage1 只读复核 matched；UIKit fixture待运行 |
| I2 | 实际SD长重载+内部setter边界，UI4/internal6/setter4 ABI分别处理；短钩子责任移除 | liveABI前置校验；UIKit待运行 |
| I3 | 取消旧load、绑定身份/代次、stopspinner、原生layout/theme；主题变化显式重prepare | 规格复核反例已修；真机首帧待验证 |
| I4 | typed bitmap/textFallback，实际加载事件，不定时截图；raw图+内容寻址/commit/epoch/坏blob修复 | fixture已写；无CGImage原生向量仍不持久化条件限制 |
| I5 | constructor/prelaunch幂等安装，无固定delay，不依赖设置页成功 | 静态检查；首屏时序真机待验 |
| D1 | removeKey明确仅记录/文件删除，NO保成品与resume，journal提交抑制迟到回调 | Foundation真实owner tests待执行 |
| D2 | 只确证Documents内relativePath+device/inode/size，拒未知和替换文件；无多目录猜删除 | Common/Host fixture待执行 |
| D3 | getAllTasks系统绑定、恢复屏障、独立background completion，旧数组/resume兼容 | 原生26+edge场景待运行；主动强杀平台未知 |
| D4 | 串行owner、immutable UI snapshot、UUID/generation/taskIdentifier、暂停双回调汇合/即时保存候选 | 原生回归待运行 |
| D5 | 实际宿主0..9状态、终态owner归档、同attempt durablehistory优先、移除UI文件存在/99.9%猜完成 | stage1/stage2已静态复核；原生待运行 |
| D6 | HTTP2xx+filemove证据、URLscheme/host校验、未知长度明确显示 | Foundationfixture待运行 |
| D7 | 每次新增独立UUID，stale completed动作拒绝，旧完成alias保留 | 原生同URL/legacycase待运行 |
| D8 | 任务专属目录+唯一目标，绝不删已有目标后保存 | Foundationfixture待运行 |
| U1 | 批量与单行共用action，标题/disabled实际能力；宿主明确重新下载 | Host/UI复核matched；真机交互待验 |
| U2 | 可见时weak timer+notification，取消pop不提前失效；结构变更才reload | UI源码复核；真机gesture待验 |
| U3 | 只豁免2个task-owned页；设置原生model，原生push；QL系统modal | UI/host桥接复核matched；真机待验 |
| U4 | 打开/分享/保存位置、native输入表单保输入且提交幂等、DynamicType多行、缓存诊断单站刷新 | UIKitfixture待运行；设备实际字号/转场待验 |
| B1 | 单一safe_macho注入owner，v9-v18旧dylib入口全转安全CLI | 本地完整前像/合成测试pass；仓库外relays只本地 |
| B2 | 原IPA/exe完整SHA/20fullpreimage/meta校验，来源embedded版/SHA+exactGitblob/currentsrc，exclusiveoutput和失败cleanup | 本地39/39测试PASS；实际CI产物来源待验 |
| B3 | target14，builder同步exe/plist/dylibminOS；不伪13兼容 | 包装testsPASS；iOS实际链接待验 |
| B4 | 日志脱敏/有界新log，历史owner快照与事件写盘，README更新，旧逻辑责任收敛 | 静态验证；真实性能/日志量待运行 |

## 已执行

- Windows 完全访问下包装/来源/文件输出回归 **39/39 PASS**，含实际原IPA到旧v18逐字节重建、完整补丁前像/metadata/hash、Git归属、真实来源清单、独占写新文件/故障清理。
- Python AST、`git diff --check` 与阶段1/阶段2独立只读复核。每项复核反馈按owner修正，不拿 review 当 runtime PASS。
- 原始IPA SHA仍 `377d37baf421ca90819a1a1624498be7776e553bb982a55f1a1173425ab9ae71`；旧v18 IPA SHA仍 `6520b10dad63dbe483a87d9463840a5f9d51bca5fe803449f62687aa5f7b999a`；旧库 SHA仍 `2b0cd57b190e5c7c00548bc0954f31db43fda64370484c6318d1c49710d1fab2`。

## 尚待交付

- 真实 macOS Foundation engine/host/common/edge 回归。
- UIKit 模拟器图标与输入表单 fixture；这不等于 Focus 真机运行。
- 完整arm64 iOS14链接，编译库metadata/来源SHA核验，生成全新v19 IPA及hash/readback。
- 用户LCSign重签覆盖安装后首帧/主题/暂停/删除真机验收。CloudKit仍禁用不可同步；不把静态友盟入口禁用当实际流量零证明。

原生完成、提交和CI结果将更新同一work checkpoint/evidence，当前不能宣称修复验收或包可用。
