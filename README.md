# FocusDM — Focus 浏览器统一下载管理（注入式 dylib）

给 Focus 2.9.7（`com.qingbin.focusbrowser`）加一个下载管理页：单一列表看全部任务、暂停 / 继续 / 删除 / 新增 URL、已完成记录永久保留。

不重编宿主，只注入一个 ObjC dylib，全部能力来自宿主已有的 `FileManager`（`+shareInstance` / `-allTasks` / `-suspendTask:` / `-startTask:` / `-cancelTask:` / `-downloadWithUrl:title:`）与 `TRSessionManager`（后台 URLSession，identifier `PPBrowserBatchDownloads`）。

## 构建

CI 在 `macos-14` 上编 arm64，产物 `FocusDM.dylib`（未签名，由 LCSign 重签）。

本地无 Mac，不要尝试在 Windows 上编译。

## 安装

两种注入方式，任选：

1. **LCSign Injector**（推荐）：选 Focus 的 IPA → Injector 里加 `FocusDM.dylib` → 签名安装。LCSign 会自己加 `LC_LOAD_DYLIB` 并重签。
2. **预注入 IPA**：用仓库外的 `_focus_ipa/inject_dylib.py` 把 dylib 写进 `Payload/PPBrowser.app/Frameworks/` 并改 Mach-O 载入命令，再交给 LCSign 签。

## 使用

设置页最底部一段多出一行「下载管理」→ 进入列表。

- 进行中：文件名 / 百分比 / 速度 / 剩余时间 / 已下载量
- 行右滑：暂停 或 继续；再右滑：删除（同时删文件）
- 导航栏 ＋：输入直链新增下载
- 导航栏 全部暂停

已完成 / 失败的记录写在 `Documents/FocusDM/history.json`，永久保留。

## 已知限制

- 引擎的任务表只在内存里（宿主没有 `getAllTasksWithCompletionHandler:`），杀掉 App 重开后，**进行中**的任务不再出现在列表里；后台下载本身仍由系统继续，完成后由 `AppDelegate` 的 `handleEventsForBackgroundURLSession` 收尾。
- 已暂停但 App 已退出的任务无法从本页续传（拿不回任务对象）。
