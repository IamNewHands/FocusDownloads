# FocusDM — Focus 浏览器下载管理、站点策略与选择性备份

为 Focus 2.9.7（`com.qingbin.focusbrowser`）注入纯 ObjC dylib；不编译期链接 Swift 私有符号。补丁版本 **v20**，最低系统 **iOS14**。

## 三个功能与边界

**v20 尚在实施与验证，当前无可安装产物。** 下面是目标清单，不是验收结果。2026-11-09 接续核对发现原导航下载、站点部分接线与备份回滚尚不满足契约；进度见 [当前 checkpoint](<docs/aegis/work/2026-11-09-focus-v20-plan-implementation/20-checkpoint.md>)。用户手机仍是稳定 v19。

| 功能 | 目标（未验收） | 明确不做 |
|---|---|---|
| ① 统一下载 | 手动直链与页内下载进同一管理页；来源站点/传输类型可见；可恢复任务；等待队列（上限 500）与可重放 GET 并发 1–6；按名称/来源搜索并按状态筛选；批量入队（单次 ≤100） | 万能视频解析、DRM、无限后台、多线程分片 |
| ④ 站点策略 | 精确 origin（scheme+host+port）的 UA/桌面模式/缩放/阅读/拦截/网页JS/用户脚本/外跳/摄像头/麦克风；原生规则列表与单站编辑页；“继承”不落盘；“本次关闭增强”只作用于当前 WebView | 重造翻译/Reader/拦截引擎、完整多身份容器、全局 VPN |
| ⑤ 选择性备份 | `.browserbackup` 单文件 JSON 容器；书签/搜索配置/站点策略/白名单偏好默认选中，用户脚本默认不选；导入前完整校验与差异预览；合并或替换所选类别；prepare/journal/回滚 | 账号密码/Cookie 迁移、恢复原 CloudKit、自动云同步 |

### ① 下载：请求来源与传输

三种传输按请求自身条件选择，不靠扩展名猜：

| 运输器 | 适用 | 限制 |
|---|---|---|
| `anonymousBackground` | 无 Cookie/秘密头、可重放的同源 GET | 后台会话已关闭自动 Cookie 共享；重定向由系统自动跟随 |
| `credentialedSession` | 需要 Cookie/Auth 的可重放 GET | 每 intent 一个 ephemeral 会话；跨 origin 302 与 HTTPS→HTTP 默认拒绝 |
| `webKitDownload` | POST、单次票据、页面生成资源 | 不重放请求；不保证 Blob/MSE/DRM |

请求上下文（Cookie、Auth、body）只存在于进程内的 `FDMIntentRegistry`，不写进 `tasks.json`、历史或备份。恢复后没有请求上下文的行显示“需要重新发起”，不会退化成匿名 GET 重试。

调度器只管尚未发起的可重放 GET：先持久化等待行再创建传输，`schedulerStatus` 为 `waiting/running/userPaused/needsContext`；并发槽在回调真正收敛后才释放。

**删除有两种明确语义：**仅删除记录（保留成品与续传候选）／删除记录与所属文件（只删身份未变的一个文件）。

### ④ 站点策略

`Documents/FocusDM/site-policies.json` 是唯一真源，字段省略或 `inherit` 表示沿用全局。UA 覆盖在 `Tab updateUserAgentWithURL:` 之后应用，所以移除覆盖会回到**当前**全局 UA 而不是硬编码 nil；缩放覆盖同理接在 `applyWebScaleForCurrentURL` 之后。

文件格式未知或损坏时保留原文件并暂停写入，UI 顶部直接说明原因，不会清空后覆盖成默认。

### ⑤ 备份与恢复

导出顺序：解析 → 校验 → base64 边界 → 长度/哈希 → 写入临时文件 → 读回校验 → 系统分享。导入顺序：完整解析 → 类别差异预览 → 按类别 prepare（含 revision 检查）→ journal → 逐类提交 → 读回校验 → committed marker → 一次性发布。

始终排除 Cookie、密码、钥匙串、Authorization、下载请求与续传数据、浏览历史、缓存、无痕数据与绝对沙箱路径。base64 不是加密，SHA256 只是完整性校验。导入的摄像头/麦克风 `allow` 一律降为 `ask`；新增或变更的脚本导入后默认禁用。

中断的恢复事务在启动时按 journal 收敛：非 `committed` 阶段一律回到恢复前配置并给出提示；回滚本身失败时保持保护状态并如实报告，不假装成功。

## 首页/书签图标

按已核实控件映射处理 `targetUrl/logo/logoLabel` 与 `url/logoImage/logoText`。缓存保存类型化位图或稳定文字占位，不截取加载中的整个容器。用户在 v19 真机测试确认图标缓存已正常。

位图命中保留原生布局/主题处理，停止加载指示器。复用 cell、迟到回调、主题切换使用模型身份与请求代次校验。

旧 `snaps` 裸 PNG 可能包含文字、底色或指示器，**保留但不自动认作可信原图**。

## 构建与验证

本机 Windows 不编译 iOS；GitHub Actions 在 `macos-15` 执行：

1. Python 包装与契约回归（含新增 `test_v20_contracts.py`）。
2. Foundation 原生回归：真实引擎配显式 FakeSession，覆盖任务/暂停/恢复/删除/保存时序，以及新增的严格 JSON、origin、策略 DTO、备份容器与重定向策略。
3. UIKit 模拟器回归：测试宿主执行真实缓存代码，SDK/控件为明确夹具，不代表 Focus 真机。
4. 编译全部 `src/*.m` 为 arm64 iOS14 dylib（链接 WebKit）。
5. 核对库内版本/完整源提交与该提交的 tracked 源码字节，生成来源清单。

```powershell
python -m unittest discover -s tests -p 'test_*.py' -v
```

CI 产物名包含补丁版本和 Git SHA，含 `FocusDM.dylib` 与 `FocusDM.provenance.json`。重复打包时 `--source-root` 必须是来源清单 `source_sha` 对应的 checkout。

## 安全打包

只接收已核对的原始 Focus 2.9.7 IPA。二进制补丁清单绑定完整 SHA 与旧字节，保留既有 VIP/CloudKit 禁用/locale/书签导入/友盟禁用改动，不扩大改点。

```powershell
python tools/build_focus.py `
  --ipa D:\GitHub_Clone\Focus_2.9.7.ipa `
  --dylib D:\GitHub_Clone\_artifacts\focusdm\v20-SHA\FocusDM.dylib `
  --provenance D:\GitHub_Clone\_artifacts\focusdm\v20-SHA\FocusDM.provenance.json `
  --source-root D:\GitHub_Clone\FocusDownloads `
  --out D:\GitHub_Clone\Focus_2.9.7_patched_v20.ipa
```

输出必须是新路径，不允许覆盖旧包。注入库、载入命令、资源、最低系统、ZIP 和补丁读回全部校验。

**安装需 LCSign 重签**，签名后覆盖安装由用户执行。CloudKit 重签权限仍不可恢复；禁用只是防崩，不是恢复同步。不要把 Python/CI 编译通过当成真机首帧、续传或主题验收。

## 数据与诊断

| 路径（`Documents/FocusDM/`） | 内容 |
|---|---|
| `downloads/` | 自建下载成品 |
| `tasks.json` | 进行中任务清单（不含请求秘密） |
| `history.json` | 已完成/失败记录，永久保留 |
| `resume/` | 断点续传数据 |
| `site-policies.json` | 站点策略唯一真源 |
| `backup-journal.json` | 进行中的恢复事务，成功后删除 |
| `diagnostics-v20.log` | 有界、脱敏日志 |

旧任务/历史数组和旧续传文件保留兼容。未知或损坏存储文件不静默覆盖。新日志只记录 taskID、代次、运输类型、method、origin、状态与 header **名称**，不记录 header 值、Cookie、请求体或含敏感 query 的 URL。

真机仍需覆盖：站点策略跨站隔离与缩放手感、网页下载进入统一列表、登录站下载、批量入队、备份导出/导入与冲突选择、强杀后 journal 恢复。

