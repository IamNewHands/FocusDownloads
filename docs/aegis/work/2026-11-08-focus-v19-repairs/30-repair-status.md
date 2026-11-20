# Focus v19 逐项修复结果

审查基线 `3e566c4569e2866cd991097494ca1f3bbb4f64d7`，实现及通过原生 CI 的源码提交 **`afb5b4d2c80c39e4c0d5e0823b5a4a5fe9ce0d69`**。用户明确授权 main 推送、macOS CI、下载新库和生成新 IPA；没有覆盖旧包、清理旧用户数据或代签安装。

## 代码修复映射

| 报告项 | 实现与责任收敛 | 已执行验证 / 未覆盖 |
|---|---|---|
| I1 | 4类页面/位图/文字精确适配，命中与成功应用分开 | UIKit fixture PASS；真实Focus首帧待真机 |
| I2 | 实际SD长重载+内部setter边界，UI4/internal6/setter4分别处理；旧短钩子移除 | ABI校验、UIKitfixture PASS、arm64编译PASS |
| I3 | 取消旧load、模型/代次保护、stopspinner、原生geometry/theme；主题显式重prepare | 复用/主题pending/本地图fixture PASS；真实控件主题待真机 |
| I4 | typedbitmap/textFallback、真实事件保存、内容寻址/epoch/commit；坏blob修复，坏epoch明确fail-closed | 新store磁盘命中/负缓存/取消/写故障/损坏回归PASS；无CGImage向量不持久化条件仍保留 |
| I5 | constructor/prelaunch幂等安装，无固定延时，不依赖设置页成功 | 静态复核和arm64编译PASS；真实首屏时序待设备 |
| D1 | 记录/文件删除分离，NO保final与resume，journal抑制迟到回调 | 原生owner/host/legacy完成历史保护回归PASS |
| D2 | 唯一确证relativePath+device/inode/size，未知/替换/目录拒绝；无猜目录删除 | common/host同名无关文件和身份回归PASS |
| D3 | getAllTasks系统绑定、恢复屏障、独立background completion，旧数组/resume兼容 | 原生恢复/批次/退出窗口回归PASS；真实强杀和Apple后台仍待真机 |
| D4 | 单串行owner，immutable UI snapshot，UUID/generation/taskIdentifier与pause双回调即时保存 | 原生两顺序/迟到代次/持久化失败回归PASS |
| D5 | 真实宿主0..9状态、终态owner提交、同attempt durablehistory优先，移除UI猜完成与集合突变 | 原生host/edge/malformed回归PASS |
| D6 | URL验证、HTTP2xx+filemove完成证据、未知长度明确显示 | 原生404/保存/输入fixture PASS |
| D7 | 新下载独立UUID，陈旧completed动作拒绝/保历史，legacy完成记录不合并删除 | 同URL/legacy/current action回归与独立复核PASS；真实菜单快速操作待真机 |
| D8 | 任务专属目录+唯一目标，绝不删旧目标再保存 | 原生保存/不覆盖回归PASS |
| U1 | 批量和单行共用action，标题/禁用状态真实能力；宿主明确重新下载 | 静态复核+nativecompile；整套用户交互待真机 |
| U2 | 可见时weak timer+notification，取消pop不提前失效，结构变才reload | 静态复核+nativecompile；真机gesture待验 |
| U3 | 仅2个自建页豁免，原生SettingModel/push；QL系统modal | 静态复核+nativecompile；真实宿主导航待验 |
| U4 | 完成预览分享/保存位置，原生输入保内容且幂等，DynamicType，缓存诊断 | UIKit表单/缓存fixture PASS；真机字号/分享/转场待验 |
| B1 | 单一safeMachO，全零cave/布局/完整输入检查；旧dylib入口全relay | 本地39/39PASS；外部relay仅本地，不属于远端源码 |
| B2 | 完整hash/preimage/meta，embedded版/SHA+exactGitblob/current摘要，exclusive输出与故障cleanup | 本地39/39、CI来源核验与新IPA独立读回PASS |
| B3 | iOS14、库/exe/plist最低系统一致；CI换受支持macOS15 | 原生编译PASS；包内minOS三处一致 |
| B4 | 新脱敏有界log、owner事件/快照写盘、文档同步、旧owner退役 | 静态复核+nativecompile；实际磁盘量/耗电性能未测 |

## 真实验证结果

- 本机 Python 包装/来源/输出回归 **39/39 PASS**，含本地真实原包→旧v18精确重建和错误输入拒绝。
- CI [42475892882](<https://github.com/IamNewHands/FocusDownloads/actions/runs/42475892882>)：源码 `afb5b4d...`；Python38项通过（本机原IPA fixture不在runner上，跳过1类）；Foundation **26下载场景**、common/host/edge/malformed全部PASS；UIKit缓存与输入表单fixture PASS；arm64库编译和provenance PASS。
- 新包 [Focus_2.9.7_patched_v19.ipa](<workspace>/Focus_2.9.7_patched_v19.ipa>)：20,613,437字节，SHA256 **`a39aee1077c9f52cbbe18a2bd393abc0978501e970c27373354d60e558f6a6b6`**。
- 包内357条，原355条中仅主exe和Info.plist变化；只新增FocusDM.dylib与来源JSON。主exe仍10,351,024字节，差异433字节（此前432补丁范围+minOS升级）；VIP/重签恒真及其他已保留补丁一致。ZIP完整性/来源/资源/哈希独立读回PASS。
- 新库320,128字节，SHA256 `1cea9db7bd2d528ceaebdce68369e40c7c2c0770a78a28e29668a30688e714b5`，embedded/source manifest与CI源提交匹配。
- 原IPA、旧v18 IPA、固定旧库哈希未变化。主提交c5f25ad为修复候选；4222580修退休runner；a01d572修真实Foundation常量/测试宏错误；afb5b4d补实际CoreGraphics链接，最终全CI成功。

## 已知边界与下一步

新包未重签，须用户LCSign重签后覆盖安装。建议先准备一次首页/书签图标，随后杀进程重进；成功位图和失败文字占位都应稳定。复制“下载管理 → 更多 → 图标缓存诊断”可获取脱敏命中/应用/写盘状态。

旧裸快照保留但不自动信任，新格式需要一次准备。**无CGImage的原生向量UIImage仍走宿主、不持久化**，不得宣称所有SVG冷启动缓存已修复；若真机仍有个别图标重载，用诊断定位实际资源/类型。真实Focus的首帧、主题、强杀、Apple续传候选接受、导航/字号/分享没有在用户手机上验证。

CloudKit依然禁用不可同步，既有VIP/签名/locale/书签/友盟补丁没有扩大。CI成功日志仍有unused-parameter/符号整数比较等编译警告，以及官方actions Node运行时提示；没有编译错误。此轮没有将警告隐藏为-Wno，也没有仅为警告重建另一个已验证包。

完成边界是逐项代码修复、已列回归/CI及新包交付，不是用户真机验收。外部 `_focus_ipa` v9–v18/inject入口只本地修改安全relay，远端提交仅FocusDownloads内本轮文件。
