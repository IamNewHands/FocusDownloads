# ADR-0001 - 单一下载状态owner与类型化图标缓存

Status: `recorded-from-work`
Date: `2026-11-08`

## Source Evidence

- afb5b4d CI42475892882原生Foundation26场景、UIKit夹具、arm64编译全部通过；新v19IPA独立读回通过
## Context

旧单文件混合宿主/自建任务和UI状态推断；图标以无类型快照及错误模型字段缓存，导致删除安全和跨启动身份不可靠

## Decision

自建任务由单串行FDMEngine拥有UUID/代次/系统任务映射与终态持久化；FDMHostDownloads仅适配已核实宿主事件；UI消费快照。图标按已核实4类身份在真实SDK边界缓存bitmap或textFallback，保留旧用户数据但不信任旧整块快照

## Alternatives Considered

- 继续在UI用进度或文件存在猜完成；短重载/定时抓图逐点补丁
## Consequences

- 迁移维持旧数组/resume和完成历史；记录删除与唯一确证文件删除分离；图标类型/来源/epoch可诊断；需要一次准备新格式缓存；无CGImage向量与真机生命周期仍需验证
## Compatibility Boundary

Focus2.9.7固定原包；VIP/CloudKit禁用/locale/书签/友盟补丁不扩大；最低iOS14；不代签安装；不清旧snaps和下载文件

## Retirement Impact

旧重复引擎/缓存责任、短钩子、无代次定时截图、UI猜完成和多路径猜删除不再执行；dylib旧入口统一转安全CLI，旧产物保留

## Baseline Sync

- Needed: needed
- Target: docs/aegis/baseline/2026-11-08-focus-v19-current.md
- Action: create snapshot
- Reason: 记录已执行的新owner/持久化/缓存和交付契约，不能用ADR代替当前状态

## Evidence References

- docs/aegis/work/2026-11-08-focus-v19-repairs/90-evidence.md
## Boundary

This ADR is an advisory Aegis Method Pack record. It does not grant completion authority or replace project-authoritative architecture sources.
