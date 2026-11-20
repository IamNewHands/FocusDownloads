# Focus v19 逐项修复计划

## 目标与批准依据

用户要求按[完整审查报告](<workspace>/_artifacts/focusdm/Focus-v18-review-20261108.md>)逐项修复。覆盖 I1–I5、D1–D8、U1–U4、B1–B4；不是只做最初两个优先问题。

本地修改、测试、独立复核及本地提交属于当前执行边界。用户随后明确批准：复核通过后推送 `IamNewHands/FocusDownloads` 的 `main`，触发现有 macOS CI、下载新构建产物并生成全新 v19 IPA；不覆盖原 IPA 或旧产物，不代签或安装。保留现有 VIP/重签/CloudKit/locale/友盟二进制补丁，不新增权益绕过，不清理用户数据。

## 架构与技术

ObjC + Foundation/UIKit + runtime，纯 Python 打包和静态验证。当前单文件同时拥有日志、存储、下载引擎、UI、图标和宿主钩子，2135 行且有重复 owner；采用有依据的职责提取，不为行数搬代码：

- `FDMCommon.h/.m`：版本、安全路径/URL、共享 runtime/日志/格式化。
- `FDMStore.h/.m`：线程安全持久化及历史记录快照，旧数组兼容。
- `FDMEngine.h/.m`：单串行后台下载 owner、任务身份/代次、恢复/终态事件。
- `FDMIcons.h/.m`：已核实控件适配、持久化图标与占位状态、实际加载事件、诊断。
- `FDMDownloadsViewController.h/.m`：纯投影、动作、打开/分享、可读性与可见性订阅。
- `FocusDM.m`：只保留宿主设置/工具栏/导航/后台启动桥接。
- `tools/`：唯一安全注入/来源验证/固定补丁构建；仓库外旧入口转发安全实现。

共用现有 FDMEngine/FDMStore/缓存能力并收敛其责任，不新增第二下载引擎；宿主任务保持原始下载语义，不强行接管登录态/cookies。最低支持系统统一为 iOS14，与既有注入库 API 一致。

## 基线、兼容与必要性

TaskStartSnapshot：工程根 <workspace>/FocusDownloads，main，HEAD 3e566c4569e2866cd991097494ca1f3bbb4f64d7；tracked/staged/unstaged/untracked 原均空；无 merge/rebase；唯一 worktree；本地与 upstream 0/0。现已新增本轮 docs/aegis 记录，非业务修改。

Change Necessity: code-change。文件删除范围、错误模型键、后台任务恢复关系和终态归档由源码决定，修改文案/重签/设置不能修复。最小边界是已有四类 owner 与打包入口；不改变原 App 的 VIP、书签导入、同步不可用边界。

Ripple/patch-shape：缓存与下载持久化均跨 UI/宿主/系统边界，修复必须在来源 owner；UI 不再通过速度/99.9%/文件存在推断完成，缓存不再通过定时截图推断图片成功。旧短 SDWebImage 钩子和未绑定代次的定时采集责任退役；旧文件保留兼容读取，不物理删除历史脚本或用户数据。

TDD Route：Mode off / Decision skipped，authority 为当前会话 TDD off；不强制 RED/GREEN。仍须新增回归测试并执行本地可运行验证，macOS 原生测试与 iOS 编译单独标注待运行。

复杂度：当前大文件过载，edit intent 为 move-out/extract-first。新模块职责边界固定，避免在通用文件新增整套状态机。目标 source/tests 尽量单文件低于800行；超出则按真实 owner 分拆。一个计划/一个 work 记录，不为每小改创建新过程文件。

## 分批实施

### 1. 下载安全与单一任务 owner（D1–D8，U1）

- 提取 common/store/engine。UUID 区分每次下载，attempt generation + taskIdentifier 防旧回调覆盖；保留旧 key 和 resume 路径兼容。
- `getAllTasksWithCompletionHandler` 恢复系统任务，先枚举再判中断；独立 FocusDM.resumable 启动 completion，didFinishEvents 后主线程调用一次。
- 用户暂停 intent 与取消回调显式协调；没有有效 resumeData 时 UI 必须说重新下载。
- 删除记录先停止/忘记、不删本地文件；连文件只操作确证路径/身份；未知路径保留并告知；完成目标不得覆盖旧文件。
- HTTP status、URL scheme、保存失败分开；终态在引擎完成，不在 UI 遍历中更改原集合；旧历史不因文件存在而被升级完成。
- 回归：旧数组读取/多次同URL、代次旧回调、暂停/恢复、历史终态、仅记录删除、路径边界/同名、403/404/未知长度。

### 2. 真实图标边界（I1–I5，U4缓存部分）

- 精确映射 BookMark/History 的 url/logoImage/logoText 与 CustomTag/ContextMenu 的 targetUrl/logo/logoLabel。
- 类型化位图/稳定文字占位，磁盘命中同步成功应用，停止指示器/取消旧请求，保留原几何与主题处理。
- 按实际长重载 completion 捕获，仅在已标记图标 view 生效，保持原 context 与四参数 UI completion ABI；其他 view 原样转发。
- 去掉短重载和定时截图，页面身份+内容签名+代次校验；失败占位持久化，默认不自动刷新，手动刷新单站。
- 启动基于已加载类安装，不依赖设置页、不用固定0.5秒；日志含memory/disk/applied/写盘结果与版本。
- 旧缓存只读兼容，避免把可能捕获spinner的旧整块快照当永久原始图标；新格式自描述。

### 3. 菜单/可读性/导航（U1–U4）

- engine/history/host 清晰投影，终态不消失、不反复上报，批量与单行共用动作；剩余宿主状态枚举以二进制核对为准。
- 只有可见页订阅，weak timer/通知，取消交互返回恢复；结构变化才 reload。
- Dynamic Type/自适应行高，名称/进度/大小/错误分行；完成行打开/分享及系统文件交付，不使用未经验证的私有 Files 定位URL。
- 仅自建下载/诊断页豁免导航断言，保持原生 SettingModel 和推入/返回，其他宿主页原样。

### 4. 打包/版本/隐私/文档（B1–B4）

- 唯一通用 Mach-O 注入：验证header、command范围、全零cave、arm64/install_name/minOS；已有入口转发，不复制两套安全边界。
- 固定补丁 manifest 从已核验的原包/现有v18差异生成并绑定完整SHA、完整旧字节、元数据身份；不扩大VIP修改。
- 原包/库/源码SHA +补丁版本 provenance；输出path必须新文件，验证失败不发布产物；不覆盖旧IPA。
- CI编译全部模块并增加原生 Foundation regression 与清单测试；版本/SHA启动日志。
- 日志按事件/错误记录、URL脱敏、限制体积；记录持久化在owner批量排队；README同步双引擎和续传限制。

### 5. 验证和逐项闭环

- 主代理回读 diff，每项问题映射实现与测试；独立规格复核后代码质量复核，不将子代理意见当真机通过。
- 本地 Python unittest、语法/manifest、实际v18 fixture差异、输出不覆盖、无遗留短钩子/定时截图/猜文件删除。ObjC原生测试/iOS编译只在已授权CI执行，不声称Windows能编iOS。
- 保存 docs/aegis/work/2026-11-08-focus-v19-repairs/20-checkpoint.md 与90-evidence.md，逐项列“已修改/本地验证/原生待编译/真机待验证”。
- 本地提交仅在本地验证与独立复核通过后进行；随后按用户明确授权推送 main、检查 macOS CI、下载与源 SHA 匹配的新库并生成全新 v19 IPA。编译或真机未通过不得宣称可用；不覆盖旧包、不代签安装。

## 验收和停止条件

首要真机判据：首次准备后退出进程重进，成功图标与失败文字占位在首页/书签首帧稳定，没有自动重拉/加载指示器/占位跳变；主题和快速复用不串图。

安全判据：仅删记录保留文件；连文件不影响同名无关文件；HTTP错误不标完成；恢复控制系统原任务；旧代次不能移除新任务。

平台未知：iOS系统终止与主动强杀差异、重签后的后台生命周期、原生布局与向量/主题效果必须真机验证。范围闭环是代码修复与本地证据，不等于上述手机行为验收。授权/信息阻断只停相关动作，继续独立本地工作。
