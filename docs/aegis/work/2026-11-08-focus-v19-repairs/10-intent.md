# Focus v19 逐项修复 - Intent

## TaskIntentDraft

- Requested outcome: 按 v18 审查逐项本地修复并验证，保留既有补丁和用户数据
- Goal: 按 v18 审查逐项本地修复并验证，保留既有补丁和用户数据
- Success evidence:
- none
- Stop condition: Stop when success evidence is satisfied or a blocker/risk requires pause.
- Non-goals:
- 未经授权不推送、联网或改旧IPA/用户数据
- Scope: FocusDownloads/src, tools, tests, CI 和 _focus_ipa 入口脚本
- Change kinds:
- bugfix
- Risk hints:
- 文件归属、持久化兼容、异步回调和私有宿主接口

## BaselineReadSetHint

- D:\GitHub_Clone\_artifacts\focusdm\Focus-v18-review-20261108.md

## BaselineUsageDraft

- Required baseline refs:
- D:/GitHub_Clone/_artifacts/focusdm/Focus-v18-review-20261108.md
- Delivered context refs:
- none
- Acknowledged before plan:
- D:/GitHub_Clone/_artifacts/focusdm/Focus-v18-review-20261108.md
- Cited in plan:
- D:/GitHub_Clone/FocusDownloads/docs/aegis/plans/2026-11-08-focus-v19-repairs.md
- Missing refs:
- none
- Advisory decision: continue

## ImpactStatementDraft

- Compatibility boundary: 旧 tasks/history 数组与 resume 文件兼容；现有 VIP 等补丁不扩大
- Affected layers:
- none
- Owners:
- FDMEngine/FDMIconCache/原生菜单入口
- Invariants:
- 不猜文件归属，不以UI推测完成，不让旧回调覆盖新任务
- Non-goals:
- 未经授权不推送、联网或改旧IPA/用户数据

These records are Method Pack drafts / hints, not authoritative runtime decisions.
