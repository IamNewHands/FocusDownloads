# Focus v19 逐项修复 - Evidence

## 已执行候选证据

- 本机 Python 包装回归：39/39 PASS，实际原包/旧v18完整前像重建、Git提交归属、资源保持、独占输出与失败清理。
- Python AST 与 git diff --check：PASS。
- Engine/Store、Host/UI、打包、图标缓存的阶段1规格与阶段2质量反馈均已修正并最终回读；这仍只是静态复核，不代替原生运行。
- CI 42475652352（提交 a01d572）Foundation native regression 实际编译并执行：FDMEngine **26 scenarios passed**；common、host、owner edge（finish-only durability/background batch/damaged storage）、malformed task 全部 PASS。
- CI 42475892882（提交 afb5b4d2c80c39e4c0d5e0823b5a4a5fe9ce0d69）最终全部SUCCESS：Foundation26下载场景+common/host/edge/malformed PASS；UIKit icon/form fixture PASS；arm64库和编译来源核验PASS。
- 新库SHA256 `1cea9db7bd2d528ceaebdce68369e40c7c2c0770a78a28e29668a30688e714b5`，320128字节；来自同一CI源码SHA，当前源字节与提交blob/provenance匹配。
- 新v19 IPA SHA256 `a39aee1077c9f52cbbe18a2bd393abc0978501e970c27373354d60e558f6a6b6`，20613437字节，357条；ZIP无错误，原资源仅exe/Info改动，新增库/来源JSON；主exe等长、433diff包含minOS升级，既有VIP等补丁保留。
- 静态源review及CI只证明其覆盖范围，不代替实际Focus重签设备验收。
- 原IPA、旧v18 IPA 与固定旧dylib SHA均与审查基线一致，未覆盖旧产物。

## 证据范围

本地包装、Foundation owner、UIKit夹具和arm64构建已执行通过，新IPA独立读回通过。它们不证明实际Focus重签冷启动首帧、手势/主题、主动强杀后台及Apple真实续传候选接受性。无CGImage向量UIImage仍不持久化，不声明所有SVG已修。详细逐项映射与下载结果见本工作目录 30-repair-status.md。

## EvidenceBundleDraft: whole-repair

- Artifact key: focus-v19-verified
- Slice ID: whole-repair
- Type: native-ci-and-package
- Source: CI42475892882 afb5b4d2c80c39e4c0d5e0823b5a4a5fe9ce0d69; <workspace>/Focus_2.9.7_patched_v19.ipa
- Summary: 本机39/39包装回归；CI Foundation26下载+common/host/edge/malformed全部PASS，UIKit图标与表单fixture PASS，arm64/provenance PASS；新IPA357条/433diff/等长/ZIP与保留补丁独立读回PASS，旧包库SHA不变；真机未重签验收，无CGImage向量仍条件限制
- Verifier: 主代理实际命令与CI日志、独立规格/质量复核、IPA字节读回
- Evidence status: evidence-finalized
