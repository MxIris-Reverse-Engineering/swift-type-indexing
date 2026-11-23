# Evolution 提案索引

- **项目类型**: 库（源码分发）—— SPM library product `TypeIndexing`，下游（MachOObjCSection、MachOSwiftSection、RuntimeViewer）从源码重编译，无 ABI 约束，但每次公开 API 变更必须评估源码兼容性。

本包从 MachOSwiftSection 拆出，与它有关的提案由 MachOSwiftSection 维护唯一一份，这里只登记链接。本包自己的提案将来放在本目录，文件名与编号规则同 MachOSwiftSection：创建时 `draft-<slug>.md`，落地时取号。

| # | 标题 | 状态 |
|---|------|------|
| [cross-repository MachOSwiftSection draft](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/draft-swift-type-indexing-package.md) | 类型索引独立成 swift-type-indexing 包，并接入 MachOObjCSection 与 RuntimeViewer：由 MachOSwiftSection 维护唯一提案；本包是搬出来的 `TypeIndexing` 本身 | In Progress |
| [cross-repository MachOSwiftSection 0009](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0009-type-indexing-revival.md) | TypeIndexing 重启：`__C` 类型模块归属解析的索引管线修复与重构（搬家前） | Implemented |
| [cross-repository MachOSwiftSection 0010](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0010-community-type-mapping-bundles.md) | 补充类型映射：私有框架 `__C` 类型的用户自备 APINotes 加载（搬家前） | Implemented |
