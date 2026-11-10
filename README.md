# FocusDM v20 — Focus 2.9.7 补丁

纯 Objective-C 注入库，目标 `com.qingbin.focusbrowser`。最低 iOS 14；网页原请求下载与本页图片需要 iOS 14.5+，媒体权限策略需要 iOS 15+。

## 使用入口

- **下载管理**：原下载菜单或设置页；手动直链、网页下载和选中图片显示在同一管理页。
- **网站设置**：当前网页菜单；**网站规则**：设置页中的全站规则列表。
- **下载本页图片**：当前网页菜单，逐项选择并确认数量。
- **数据备份**：设置页，勾选类别导出；导入先选文件和类别，再看差异预览。用户脚本默认不选。

## 功能与限制

| 功能 | 当前实现 | 明确限制 |
|---|---|---|
| 下载 | 来源与传输类型、搜索/状态筛选、手动 GET 队列、批量直链、本页图片、暂停/可用续传、两种删除方式 | 可重放 GET 并发 1–6，默认 3；队列 500、每批 100。原网页 WKDownload 不承诺相同后台能力或并发限制 |
| 站点策略 | 精确 `scheme://host:effectivePort`；桌面/移动模式、UA、缩放、Reader、内容拦截、页面 JS、用户脚本、外部 App、摄像头/麦克风；当前标签临时关闭增强 | 不向子域继承；不改变系统 TCC、TLS。宿主 Reader/脚本/拦截能力沿原实现，非重造引擎 |
| 本地备份 | 书签、首页快捷项、搜索配置、站点策略、白名单偏好、可选脚本；差异预览、保留本地冲突或替换所选类别、失败回滚/启动恢复 | `.browserbackup` 不加密。不恢复 Cookie、账号密码、CloudKit 权限或活动网络会话；不自动上传 |

### 请求与数据

- 原网页下载响应使用 `WKNavigationResponsePolicyDownload` 接管，POST/单次票据不重放为 GET。
- 图片选择是用户明确发起的新请求，沿来源 WebView 上下文；不是重新请求已经发出的 POST。
- 匿名后台会话禁用环境 Cookie/凭据共享。带 query、片段或非白名单请求头的手动 GET 不进入匿名后台。
- 新请求秘密与平台续传数据只进进程内存或设备本地 Keychain，公共历史不保存原请求秘密。退出后缺少上下文的网页任务要求回来源重新发起，不自动切换运输器。
- “仅删记录”保留成品；“删除记录与所属文件”只处理身份已确认的成品。不清旧下载目录、历史或图标缓存。

### 备份恢复

导入先校验完整文件，再选类别，显示新增/相同/冲突/不支持/权限降级/脚本禁用数量。默认合并保留本地同 ID 冲突；替换展示单独预览并二次确认，执行使用已展示计划，不在确认时悄悄换版本。

原宿主 SQLite、NSUserDefaults、站点策略仍各自拥有数据；恢复只保留事务期间的本地前像和读取快照，不另建运行期配置库。提交前记录 prepared；回滚先记录 rollbackPending。回滚失败保留记录与保护界面，不能把混合配置当正常启动。

新增/改变脚本禁用，原文 `.js` 与元数据读回校验；摄像头/麦克风 Allow 导入降为 Ask。相同脚本必须包含完整元数据等价，不能只比较名称和代码。

限额：文件 32 MiB、解码总量 16 MiB、单类别 8 MiB、JSON 深度 32、书签 10000、脚本 200/单条 1 MiB。base64 不是加密，SHA256 不是来源认证；书签 URL 与脚本仍可能含私密信息。

## 验证与交付状态

当前进度与精确来源见 [checkpoint](<docs/aegis/work/2026-11-09-focus-v20-plan-implementation/20-checkpoint.md>)，执行证据见 [证据记录](<docs/aegis/work/2026-11-09-focus-v20-plan-implementation/90-evidence.md>)。

截至 2026-11-10，用户已安装 v20，并反馈备份导出失败、页面进入时顶部闪透和侧滑退出残留。**这些真机问题尚未验收通过，不能用旧包或编译成功替代验收。**

- 原始 v20 来源 `1de62778369a7c9f24280db9eeb2832ff3c34bfe` / CI42813107978 已完成其对应的原生、WebKit 和包装验证；这是历史批次，不是当前源码来源。
- 前一轮菜单修复来源 `dcab80e46dd498a42d023aa795caff2f4d326dc5`，已有旧包 `Focus_2.9.7_patched_v20_fix_dcab80e.ipa`；不包含后续导出与转场修复。
- 本轮修复来源 `a110b46b9f8863ef5bf0ee89039b486f5576aa4c` 已推送。本地 74 项 Python 检查通过；CI42837951395 的 Foundation、WebKit、arm64 编译通过，但备份错误诊断和 UIKit 回调时序测试失败。
- 来源清单校验和产物上传被总门禁阻止。本地已修正错误回写和异步测试时序，76 项检查通过；原生重跑仍待结果，本轮尚无可交付新 IPA，详见 [本轮记录](docs/focus-v20-device-regressions-2026-11-10.md)。

v19 图标实现与既有二进制补丁清单保持不变。原包、旧包不覆盖。

## 构建与打包

GitHub Actions 使用 macOS/Xcode SDK 编译 arm64，全部必要原生目标通过后才上传库与来源清单。Windows 本机不安装替代 iOS 工具链。

```powershell
python tools/build_focus.py `
  --ipa D:\GitHub_Clone\Focus_2.9.7.ipa `
  --dylib <CI下载目录>\FocusDM.dylib `
  --provenance <CI下载目录>\FocusDM.provenance.json `
  --source-root D:\GitHub_Clone\FocusDownloads `
  --out D:\GitHub_Clone\Focus_2.9.7_patched_v20.ipa
```

输出必须不存在。打包器验证原 IPA SHA、Mach-O 加载命令、来源提交/源码字节、允许的二进制差异、所有资源及 ZIP 读回；不扩大既有 VIP/CloudKit/统计补丁改点。

**新包准备好后，由用户使用 LCSign 重签。** 沿用当前安装的 bundle ID/签名方案覆盖安装，先备份重要数据；不要先卸载当前版本，否则其应用容器可能被删除。重签不能恢复原应用 CloudKit entitlement。

真机待验证范围：实际 Focus 菜单与宿主缓存重载、Reader/拦截组合、真实设备强杀/后台续传及旧 iOS 版本、VoiceOver 与大字号。Blob/MSE/DRM 不承诺支持。
