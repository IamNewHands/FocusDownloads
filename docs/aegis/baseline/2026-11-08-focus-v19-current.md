# Focus v19 当前实现基线

记录已执行架构，证据提交 `afb5b4d2c80c39e4c0d5e0823b5a4a5fe9ce0d69`；决策见 [ADR-0001](<../adr/ADR-0001-safe-download-owner-and-typed-icons.md>)。本文件不声称真实Focus运行已验收。

## 所有权与契约

- FDMCommon：安全URL/路径/文件身份、实际消费字段验证、脱敏有界日志、版本/Git标识。
- FDMStore：历史不可变快照、原子写入/错误保护，旧数组字段兼容，不由UI遍历修改。
- FDMEngine：自建NSURLSession单串行状态owner，任务UUID+generation+taskIdentifier；系统任务恢复屏障；暂停双回调事务；成功move即提交终态证据；后台完成批次主线程交接；仅记录删除与文件删除明确分离。
- FDMHostDownloads：已核实Focus2.9.7宿主status0..9和main进度/成功/失败通知的适配；宿主下载保持原引擎，恢复只能重新下载，不伪续传。
- FDMDownloadsViewController：纯状态投影、原生导航/操作、完成预览分享、保输入和提交幂等、可见订阅。
- FDMIcons/FDMIconDiagnostics：精确4类控件适配；真实SD长/内部setter与主题边界；typedbitmap/text、写盘commit/applied区分、baseepoch刷新及损坏fail-closed；诊断可复制/单站刷新。
- FocusDM：宿主设置/工具栏/导航和AppDelegate后台启动接线，不另拥有下载/缓存数据。
- tools：唯一safeMachO/完整前像/来源提交校验及独占新包输出。库embeddedmetadata、exactGitblob/currentfile摘要、原包hash与ZIP资源读回必须相符。

## 保留与退役

旧 tasks/history 数组与旧resume路径兼容；旧完成历史不得被新下载alias隐藏或删除。旧snaps、旧icons及下载文件不自动清理。无类型旧整块快照不自动提升为可信原图，新格式需要准备一次。

不再执行短SD重载钩子、定时截图猜成功、UI用速度/99.9%/非空文件猜完成、多目录同名文件删除、重复URL充当新任务身份。仓库外旧dylib builder v9-v18/通用入口仅本地转发安全CLI，不属于远端仓库提交资产。

## 环境和已验证边界

最低iOS14，CI使用受支持macOS15（macOS14已退休）。本地包装39/39通过；CI42475892882实际Foundation26下载场景+common/host/edge/malformed通过，UIKit图标/表单fixture通过，arm64库编译和来源清单通过。新v19IPA独立ZIP/patch/resource/hash/readback通过。

模拟器使用夹具SDK/控件并执行真实修复模块，不等于真实Focus首帧或重签后台。CloudKit依然禁用不可同步，既有VIP/locale/书签/友盟补丁范围不扩大。原生向量UIImage无CGImage条件尚不持久化；不宣称所有SVG或真机首帧已验收。实际设备的冷启动、主题、手势、强杀和Apple续传候选接受性由用户重签安装后验证。
