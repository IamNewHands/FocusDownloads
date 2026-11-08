# FocusDM — Focus 浏览器下载管理与图标缓存修复

为 Focus 2.9.7（`com.qingbin.focusbrowser`）注入纯 ObjC dylib；不编译期链接 Swift 私有符号。补丁版本 **v19**，最低系统 **iOS14**。

## 功能与边界

| 来源 | 暂停/恢复 | 跨启动 | 历史 |
|---|---|---|---|
| 下载管理 `＋` 新增 | 自建后台 NSURLSession；有效 resumeData 才标“断点继续”，否则明确“重新下载” | 枚举系统任务重新绑定；主动强杀和系统终止行为不同，不作无限后台保证 | 每次下载独立任务 ID，不按 URL 合并 |
| 浏览器内下载 | 保留宿主引擎；本页停止并保留记录，恢复操作为重新下载 | 宿主任务仅在内存；退出后保存的记录仍可查看/重试 | 订阅宿主进度/成功/失败事件，依据真实状态与保存结果归档 |

设置中复用原生菜单行；工具栏“下载管理”先收起面板，使用原生推入与返回。列表显示名称、状态、已下/总大小、错误与恢复方式。完成记录可预览/分享，通过系统分享保存到其他位置。

**删除有两种明确语义：**

- 仅删除记录：停止跟踪并隐藏记录，不删除已保存文件或续传候选文件。
- 删除记录与所属文件：只删除该记录确证且身份未变的一个文件；未知旧路径、被替换文件或同名目录均拒绝删除，不猜测其他保存目录。

## 首页/书签图标

按已核实控件映射处理 `targetUrl/logo/logoLabel` 与 `url/logoImage/logoText`。缓存保存类型化位图或稳定文字占位，不截取加载中的整个容器。已有缓存默认不重拉，支持下载管理 → 更多 → 图标缓存诊断 → 单站刷新。

位图命中保留原生布局/主题处理，停止加载指示器。复用 cell、迟到回调、主题切换使用模型身份与请求代次校验。诊断区分命中来源、成功应用和磁盘提交；可复制脱敏文本。

旧 `snaps` 裸 PNG 可能包含文字、底色或指示器，**保留但不自动认作可信原图**。升级后需要准备一次新格式缓存，不等于每次启动重新加载。

## 构建与验证

本机 Windows 不编译 iOS；现有 GitHub Actions 在 `macos-14` 执行：

1. Python 安全包装回归（本机有原 IPA 时另核对旧 v18 完整前像）。
2. Foundation 原生回归：真实引擎配显式 FakeSession，不联网，覆盖任务/暂停/恢复/删除/保存时序。
3. UIKit 模拟器回归：测试宿主执行真实缓存代码，SDK/控件为明确夹具，不代表 Focus 真机。
4. 编译全部 `src/*.m` 为 arm64 iOS14 dylib。
5. 核对库内版本/完整源提交和该提交的 tracked 源码字节，生成来源清单。

```powershell
python -m unittest discover -s tests -p 'test_*.py' -v
```

CI 产物名包含补丁版本和 Git SHA，含 `FocusDM.dylib` 与 `FocusDM.provenance.json`。源与库身份不匹配即拒绝打包；来源清单是内部一致性核验，不是第三方签名证明。

## 安全打包

只接收已核对的原始 Focus 2.9.7 IPA。二进制补丁清单绑定完整 SHA 与旧字节，保留既有 VIP/CloudKit 禁用/locale/书签导入/友盟禁用改动，不扩大改点。

```powershell
python tools/build_focus.py `
  --ipa D:\GitHub_Clone\Focus_2.9.7.ipa `
  --dylib D:\GitHub_Clone\_artifacts\focusdm\v19-SHA\FocusDM.dylib `
  --provenance D:\GitHub_Clone\_artifacts\focusdm\v19-SHA\FocusDM.provenance.json `
  --source-root D:\GitHub_Clone\FocusDownloads `
  --out D:\GitHub_Clone\Focus_2.9.7_patched_v19.ipa
```

输出必须是新路径，不允许覆盖旧包。注入库、载入命令、资源、最低系统、ZIP 和补丁读回全部校验。仓库外 v9–v18 及通用旧入口均已转发同一显式安全命令；不再读取固定旧库或覆盖默认旧包。

**安装需 LCSign 重签**，签名后覆盖安装由用户执行。CloudKit 重签权限仍不可恢复；禁用只是防崩，不是恢复同步。不要把 Python/CI 编译通过当成真机首帧、续传或主题验收。

## 数据与诊断

自建文件在“文件 → 我的 iPhone → Focus → FocusDM → downloads”。每条记录保存精确位置，不通过名称搜索删除。

旧任务/历史数组和旧续传文件保留兼容。未知或损坏存储文件不静默覆盖；UI 提示写入/恢复错误。新日志使用有界、脱敏 `diagnostics-v19.log`，旧 `crash.log` 不清理。

本轮实现与验证记录见 [逐项修复计划](<docs/aegis/plans/2026-11-08-focus-v19-repairs.md>) 和 [修复 checkpoint](<docs/aegis/work/2026-11-08-focus-v19-repairs/20-checkpoint.md>)。真机仍需覆盖：首页/书签冷启动、断网负缓存、快速复用、主题/字号、暂停与强杀后恢复、两种删除及同名无关文件。
