# Focus v19 逐项修复 - Evidence

## 已执行候选证据

- 本机 Python 包装回归：39/39 PASS，实际原包/旧v18完整前像重建、Git提交归属、资源保持、独占输出与失败清理。
- Python AST 与 git diff --check：PASS。
- Engine/Store、Host/UI、打包的阶段1规格与阶段2质量已独立复核并按反馈修正；缓存阶段1已匹配，阶段2最后一项损坏epoch fail-closed修正收尾。
- 原IPA、旧v18 IPA 与固定旧dylib SHA均与审查基线一致，未覆盖旧产物。

## 证据范围

这些证明本地代码和包装契约，不证明 macOS/iOS 编译或 Focus 真机首帧、强杀恢复。CI 原生 Foundation、UIKit fixture 和 arm64 编译尚未执行；同源SHA新库及IPA待生成验证。详细逐项映射见本工作目录 30-repair-status.md。
