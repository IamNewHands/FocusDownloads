# Focus v20 三项功能实施与纠偏 — Intent

## Outcome / authority

用户原请求：按 [实施方案](<workspace>/_artifacts/focusdm/iOS-Browser-1-4-5-Implementation-Plan-20261108.md>) 完成 Focus 2.9.7 的①统一网页上下文下载、④精确站点策略、⑤选择性本地备份恢复；采用注入 dylib 可行路径。2026-11-09 用户两次要求继续，当时确认手机仍 v19；这是历史设备状态。

2026-11-10 用户已安装 v20，并反馈备份导出失败、顶部闪透和侧滑退出残留。本轮要求修复设备回归、校正交付记录并处理失败的 GitHub Actions。最新状态以 [checkpoint](20-checkpoint.md) 和 [本轮记录](../../../focus-v20-device-regressions-2026-11-10.md) 为准。

非目标：授权/DRM/万能视频、恢复原 CloudKit、云同步、标签组/离线库；不清下载、书签、缓存；不改稳定图标 owner。TDD Mode off / Decision skipped：不强制RED/GREEN，行为回归仍必需。

## Historical TaskStartSnapshot

- 2026-11-09 接续根：<workspace>\FocusDownloads；main；HEAD `992855ac268082cebe592b4db9c1813a64e240e5`；origin/main 0/0；无进行中Git操作；一个工作树。
- 接续时 tracked/index clean；未跟踪 src/tests/tools/docs/.github 为空。保留已有 tests 临时目录与无关根目录探针，不 reset/stash/clean。
- 原包主二进制 SHA256 `6af11eb309cc7f2d75bd87ddaf4f6fb231305825a876678ae1414e2b7fcf424c`。
- 既有 v19 编译来源 `afb5b4d2c80c39e4c0d5e0823b5a4a5fe9ce0d69`。新实验v20三次CI全部失败，没有新交付。

## BaselineReadSet / usage

已读原计划全部475行；[v19基线](<../../baseline/2026-11-08-focus-v19-current.md>)、[ADR-0001](<../../adr/ADR-0001-safe-download-owner-and-typed-icons.md>)、当前 FDMEngine/FDMIntent/FocusDM/FDMPolicy/FDMJSON/FDMBackupCoordinator/test与build合同。原二进制本地ObjC/calls/capstone用于宿主语义取证。原生平台验收依赖GitHub macOS CI；Windows字符串测试不能代替。

## Change Necessity / boundary

Decision code-change：当前源码未实现方案核心契约。增加菜单、FakeSession测试和journal名称都不能证明用户结果；必须修到canonical owner。

- 下载：FDMEngine唯一状态owner；transport只带taskID+attempt+transportIdentity报告事件；网页已有响应用WKNavigationResponsePolicyDownload，不startDownload重放；秘密只进内存recipe、公共历史只安全显示。
- 站点：FDMPolicy唯一store/resolver；navigation aggregator只接一次；脚本/Reader/拦截沿实际宿主registry；权限由实际request origin，TLS/TCC不改变。
- 备份：类别DTO与持久repository分开，禁用HTML导入/cache-only伪恢复；journal含确证before/after，启动恢复未完成事务再暴露配置。

## Complexity / review

ArchitectureReviewRequired yes。FDMEngine已1184行、多transport混合；保留串行状态生命周期，把WebKit/credentialed执行隔离；禁止继续在UI推断权能。FDMBackupCoordinator混合所有provider且1001行，重做真实repository与事务接口分界，不新增影子运行数据库。FocusDM保留接线，导航策略放独立模块但不设第二policy owner。共享状态store与delegate保持单作者；只读取证可并行。危险数据操作只作为用户明确选择的运行期导入/删除，不在此主机执行。

## Stop / verification

结束标准：当前 patch 必要原生回归、编译与来源清单通过；新包独占写入、来源对齐、资源 ZIP 与 hash 读回。设备回归须分别复测导出、顶部闪透、一次侧滑返回及取消返回；真机未验证不得写 PASS。历史 JSON 草稿是接续时的快照，不表示最新进度。
