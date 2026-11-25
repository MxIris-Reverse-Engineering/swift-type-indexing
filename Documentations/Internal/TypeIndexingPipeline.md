# TypeIndexing：`__C` 类型的归属与 Swift 名索引实现说明

> 面向维护者的实现说明：管线、缓存布局与已知降级。本模块原是 MachOSwiftSection 的 `TypeIndexing` target，由它的跨仓库提案[0105《类型索引独立成 swift-type-indexing 包》](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0105-swift-type-indexing-package.md)搬到这里；此前的设计来历见 MachOSwiftSection 的提案 [0009](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0009-type-indexing-revival.md)（TypeIndexing 重启）与 [0010](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0010-community-type-mapping-bundles.md)（补充映射），文中「提案 0009 / 0010 / 0023」都指 MachOSwiftSection 的提案。

## 这个模块做什么

Swift mangling 把 C / Objective-C 导入的类型记成 `__C.X`：模块是占位的 `__C`，`X` 是 C 名（ObjC 类是运行时名），Swift 侧的改名与所属模块都不在二进制里。`TypeDatabase` 借本机的 SDK 回答两件事：`X` 是哪个模块声明的（`moduleName(forTypeName:)`），它在 Swift 里叫什么（`swiftName(forCName:category:)`）。另外还回答一件与 `__C` 无关的事：被 SDK 用 `@_originallyDefinedIn` 搬过模块的原生 Swift 类型，现在由哪个模块声明（`declaringModuleName(ofMovedTypeNamed:originallyDefinedIn:builtAgainst:)`，见「搬家记录」一节）。本包不读 Mach-O：私有类型的归属靠调用方传入的 `DeclaredTypeNameSource`（MachOObjCSection 的 `ObjCDeclaredTypeNames` 读 ObjC 元数据实现它）。

使用方：MachOSwiftSection 的 `SwiftTypeNameResolution`（把它适配成打印器的 `ModuleNameResolving` / `CImportedNameResolving`，`swift-section interface --resolve-c-module-names` 用它）、MachOObjCSection 的 `ObjCTypeIndexing`、RuntimeViewer。

## 查询数据流（三源合并，优先级从高到低）

```
moduleName(forTypeName: "NSString")
    1. apiNotesModuleNamesByTypeName  ← API notes 的 C 名，再登 SwiftName 拼写
                                        （SDK API notes → 用户补充文件按传入序，后写覆盖）
    2. interfaceModuleNamesByTypeName ← 模块接口里的类型名
    3. runtimeModuleNamesByTypeName   ← DeclaredTypeNameSource 懒读（最低，只补缺）

swiftName(forCName: "CFStringRef", category:)   ← identifier 重写（见下节）
    1. APINotes 改名表（按声明类别隔离；补充包条目同表、后写覆盖）
    2. CF `Ref` 剥除规则（剥后名必须存在于归属表；protocol 类别不适用）
```

## ObjC 头文件的 Swift 命名标注

`swiftImportAnnotations(forObjCClassNamed:)` / `forObjCProtocolNamed:` 给 Objective-C 头文件的打印方（MachOObjCSection）用：类或协议本身、以及它的方法与属性在 API notes 里的 `SwiftName` / `SwiftPrivate`，打印时还原成 `NS_SWIFT_NAME(...)` / `NS_REFINED_FOR_SWIFT`。

- 只来自 API notes，不需要 sourcekitd；`index` 用一个不选任何模块的 `moduleFilter` 调一次就够。
- 只登记带了这两个属性之一的条目。成员的键与 API notes 一致：方法按 selector 加类 / 实例方法，属性按名字加类 / 实例属性；属性条目不写 `PropertyKind` 时同时算实例与类属性（clang 的 `APINotesYAMLCompiler.cpp` 就是这样读的）。
- 跨文件合并：几个模块的 API notes 为了标注自己的 category 方法都会列 `NSObject`，成员逐个累加、后读的文件按成员覆盖；没写类本身标注的列法不会抹掉先前的类标注。
- 存的是原始的两个属性，不是推导后的 Swift 名：成员一级要打印的是宏。
- 依赖 swift-apinotes 0.3.0：此前它的 `ObjCContext.methods` / `properties` 是 internal，包外读不到。

## 搬家记录：被 `@_originallyDefinedIn` 搬过模块的 Swift 类型

MachOSwiftSection 的提案 [0107-moved-swift-type-modules](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0107-moved-swift-type-modules.md) 加的第二类数据，与 `__C` 无关：Apple 把一个 Swift 类型从一个模块搬进另一个模块时，给声明加上 `@_originallyDefinedIn(module: "旧模块", 平台 版本)`，编译器此后在每个部署目标上都按旧模块做 mangling（Swift 源码 `lib/AST/Decl.cpp` 的 `getAlternateModuleName()`；属性是否生效只看平台、不看版本，`lib/AST/Attr.cpp` 的 `isActivePlatform`），嵌套在它里面的类型也跟着用旧模块。所以二进制只会写 `CoreGraphics.CGFloat`、`SwiftUI.View`，SDK 的接口写的却是 `CoreFoundation::CGFloat`、`SwiftUICore.View`。`declaringModuleName(ofMovedTypeNamed:originallyDefinedIn:builtAgainst:)` 回答现在由哪个模块声明。

- **数据来自文本 `.swiftinterface`，不来自 sourcekitd**：sourcekitd 生成的接口不留属性，而且只为依赖过滤命中的模块生成，而搬家后的模块常常不是二进制的直接依赖。`MovedTypeIndex` 在第一次 `index` 的 `discoverSDK()` 里扫描 SDK 里**每一个**模块：在 `.swiftmodule` 目录下挑 `<架构>-apple-<平台后缀>.swiftinterface`（`SDKPlatform.textualInterfaceTargetSuffix`；`.private` / `.package` 接口的后缀不同，自然排除；几种架构按文件名取第一个，属性对每个平台都写全，所以选哪个都一样），没有文本接口的模块跳过，读失败记日志跳过。
- **扫描规则**：编译器打印接口时一个属性占一行，而这个属性只出现在顶层声明上，所以只看第 0 列。连续的属性行组成一组，组后第一行是声明；声明行开头也可能带属性（`@frozen public struct …`），去掉属性和修饰词后剩下的才是声明。`struct` / `class` / `enum` / `protocol` / `actor` / `typealias` 才记，extension、func、var 丢掉。缩进行（成员）和 `#if` / `#else` / `#endif` 都让这一组作废；注释与空行不影响。
- **模块名**：`module:` 的值写成 `"Swift;CompatibilitySpan"` 时，分号前是 mangling 用的模块，分号后是链接用的库（`OriginallyDefinedInAttr` 的 `ManglingModuleName` / `LinkerModuleName`）。取前半段；它等于声明所在的模块（标准库的 `Span`）就不算搬家。
- **版本判断**：表里逐个声明存「平台 → 搬家版本」，同一模块的不同声明搬家时间不同（SwiftUICore 有 macOS 15.0、15.2、26.0、27.0 几批）。调用方传入二进制编译所用的 SDK 版本（`LC_BUILD_VERSION` 的 `sdk`），不低于搬家版本才回答。平台取法照编译器的平台继承（`lib/AST/PlatformKindUtils.cpp`）：Mac Catalyst 先看 `macCatalyst` 条目、没有就用 `iOS` 的（版本号相同）；visionOS 先看 `visionOS`、没有就用 `iOS` 并换算（iOS 17 = visionOS 1，18 = 2，26 起相同，17 以前视为 visionOS 出现前就已搬家）；模拟器与真机同。属性没写某个平台，就是在那个平台不生效，mangling 本来就是新模块，回答 `nil`。
- **同一个键两个模块都声明**：按发现顺序（搜索路径优先级）先到先得，记一条日志。
- **已知偏差**：属性的版本不一定等于源码真正搬家的时间。`CGFloat` 写的是 macOS 10.0，SDK 的 `libswiftCoreFoundation.tbd` 里的 `$ld$previous` 却显示部署目标在 10.15–13.0 时它链接到 `libswiftCoreGraphics.dylib`，即运行时 macOS 13 才搬。这里信属性。
- **成本**：macOS 27.2 SDK 有 368 个 `.swiftmodule`、266 份 macOS 文本接口；带上扫描后，一次只读 API notes 的 macOS 索引（`moduleFilter` 不选任何模块）在公司那台 10 核 Mac Studio 上单独跑约 1.7 秒（`SDKIntegrationTests.cgFloatMovedFromCoreGraphicsToCoreFoundation`）。扫描先用 `contains("@_originallyDefinedIn")` 跳过不含这个属性的文件。

## Identifier 重写：C 拼写 → Swift 拼写（用户指正驱动）

module 名替换之外，`__C` 类型的 **identifier 本身**也可能是 Swift 里不存在的 C 拼写——首轮端到端输出的 `CoreFoundation.CFStringRef` 被用户指正：`CFStringRef` 是 C 侧 typedef 名，ClangImporter 剥 `Ref` 后缀桥接为原生 class `CFString`。落地为打印侧对 `swiftName(forCName:category:)` 的消费（该协议方法此前零消费者）：

- **只在 module 解析成功时重写**（`printModule` 返回是否命中），未解析的 `__C.CFStringRef` 绝不渲染成半吊子 `__C.CFString`。
- **查询必须带声明类别**（`ImportedTypeNameCategory`；MachOSwiftSection 的适配层把打印器的 `CImportedTypeNameCategory`——由 mangling 的 `Node.Kind` 映射：class / protocol / 值类型 / other——一一映射过来）。这是第一版合并改名表当场踩出的回归：ObjC 的 class `NSObject` 与 protocol `NSObject` 同名，APINotes 只把 **protocol** 改名为 `NSObjectProtocol`——类别盲查让所有 class 继承行都被错写成 `NSObjectProtocol`（而 protocol 继承行反而是被修对的）。`APINotesIndex` 的改名表按 Classes / Protocols / 值类型（Tags + Enumerators + Typedefs）三张隔离，`.other`（typealias 等 mangling 不定类别的引用）查值类型表再查 class 表、**永不查 protocol 表**。
- **CF `Ref` 剥除**是 APINotes miss 后的兜底规则：`Ref` 结尾且剥后名真实存在于归属表才重写（碰巧以 `Ref` 结尾的 ObjC 类不受影响），protocol 类别不适用（无 CF protocol 惯例）。
- 归属表（`moduleNamesByCName`）不拆类别——同名实体同模块，归属无歧义。
- **`Ref` 规则对整个 `objc_bridge`（`CF_BRIDGED_TYPE` / `CV_BRIDGED_TYPE` 等各框架宏别名）家族通用**，不是 CoreFoundation 专属——判据只是「剥后名存在于索引」。CG / CV / CM 探针实测（链 CoreGraphics + CoreVideo + libswiftCoreMedia 的 dylib）：同一类型**两种 mangling 形态并存**——符号签名用 C typedef 名（`__C.CGContextRef`），字段元数据用剥后名（`__C.CGContext`）——分别由剥除规则与归属表直查覆盖（提案 0023 之后字段元数据也按描述符 import info 里的 ABI name 拼成 `__C.CGContextRef`，两种形态合一，只靠剥除规则），全部解析为 `CoreGraphics.CGContext` / `CoreVideo.CVBuffer` / `CoreMedia.CMFormatDescription`（`CVPixelBuffer` 在 mangling 层已归一为 `CVBuffer`，输出如实反映 ABI）。CoreMedia 仅以 `libswiftCoreMedia` overlay 形式出现在依赖里，`libswift` 前缀剥除使过滤命中其 SDK 模块——overlay-only 依赖场景成立。

- **Swift interface 类型名**：对二进制依赖命中的每个 SDK 模块，经 sourcekitd `editor.open.interface`（带 `key.enablesubstructure`）生成含 ObjC 导入声明的 Swift 视角 interface，`InterfaceTypeNameExtractor` 从结构树提取 fully-qualified 类型名。**不用 SwiftSyntax**（体积裁定，见提案 A′ 节）；`.swiftinterface` 文件也不可用——它只含 Swift 声明，而本功能主要目标恰是 ObjC 导入类型。
- **APINotes**：`.apinotes` 是编译器视角的权威归属记录，`APINotesIndex` 把**每个列出的实体**（含无 `SwiftName` 改名、含 `SwiftPrivate`）的 C 名注册到声明模块。它与模块接口各占一张表，查询时先查 API notes 表：`index` 可以多次调用，后来追加的接口名因此不会盖掉 API notes 的结果（原先同一张表、写入时覆盖，只在「整个数据库一次建成」时成立）。双向改名表（`swiftName(forCName:)` / `cName(forSwiftName:)`）按 Clang importer 的规则（`ImportName.cpp`）收：有 `SwiftName` 就用它，不论是否 `SwiftPrivate`（importer 遇到 swift_name 直接返回，不再看 swift_private）；只有 `SwiftPrivate` 时是 `__` + C 名（UIKit 的 `UICellConfigurationState` → `__UICellConfigurationState`）。枚举成员（`Enumerators`）只收 `SwiftName`，它们不是类型，`__` 的位置也按 enum case 的规则另算。搬家之前 `SwiftPrivate` 实体一律不进改名表，`__C.UICellConfigurationState` 因此印成与 Swift 结构体同名的 `UIKit.UICellConfigurationState`——那是 0009 落地时沿用历史实现的保守做法，当时没有记录理由。
- **运行时元数据懒读**：前两层 miss 才按登记顺序逐个读 `DeclaredTypeNameSource.declaredTypeNames()`（MachOObjCSection 的实现列出 class / protocol / C struct / union 名），并入「名字 → image 模块名」，命中即止；先登记的 image 赢得同名归属。读过的结果缓存在 actor 内；抛错的 source 记日志后丢弃不重试；同一 image 路径重复登记不会再加一次。依赖耗尽后 miss 只花一次字典探查。

## 补充映射：私有框架的外部知识入口（提案 0010）

AttributeGraph 这类私有框架在 SDK 里没有任何模块（无头文件、无 swiftmodule、无 apinotes），三源全 miss；而 `AG_SWIFT_NAME(Graph)` 的改名在二进制里只剩消费方类型记录名字字段里的最后一截 `Graph`，所属模块与嵌套关系都不记录，完整的 `AttributeGraph.Graph` 原理上无法从二进制恢复。[提案 0010](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0010-community-type-mapping-bundles.md) 的补充映射就是这份外部知识的入口：映射用**标准 `.apinotes` 格式**表达（零新格式，直接进 `APINotesIndex` 既有管线，类别隔离天然携带），**全部由用户自备**——宿主经 provider 的 `supplementaryAPINotesURLs:`、CLI 经 `--supplementary-apinotes`（可重复，文件或目录）传入；库自身不内置任何映射（首版曾内置 SPM resource bundle，review 后按用户裁定移除：`Bundle.module` accessor 在 bundle 缺失时 fatalError，而 `build-executable-product.sh` 只分发裸二进制，分发出去一用就崩——纯用户自备把整个 resource 分发问题结构性消掉）。覆盖顺序：SDK APINotes → 用户文件按传入序，`APINotesIndex.register(files:)` 的后写覆盖即优先级实现。面向用户的公开指引见 [SupplementaryTypeMappings.md](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/SupplementaryTypeMappings.md)。

**同一个 CF-bridged 类型有两种 mangling 形态**（AG probe 实测：手造 clang module 复刻 `objc_bridge` + `swift_name` 声明，5 处引用全解析为 `AttributeGraph.Graph` / `.Subgraph`；当时还有第三种，见第 3 条），各自的覆盖机制不同：

1. **typedef 名**（`__C.AGGraphRef`，符号签名，typealias node → `.other` 类别）：`Typedefs` 条目的改名表命中。
2. **storage / tag 名**（`__C.AGGraphStorage`，字段元数据的 foreign **class** descriptor，`.objcClass` 类别）：条目按 C 语义归 `Tags`（值类型表），所以 `.objcClass` 查询在 class 表 miss 后**回退值类型表**。安全性论证：C 的 tag namespace 与 ObjC class namespace 理论上可同名共存，但 class 表先查先赢，「改名只在 tag 侧、同名 ObjC class 又真被引用」无已知真实实例；protocol 表仍绝不回退（`NSObject` 隔离不动）。系统 dyld cache 的 SwiftUI 里实测存在孤立的 `AGGraphStorage` descriptor 名，即此形态。
3. **导入名直出**（`__C.Graph`，已不再出现）：消费方二进制 emit 的 foreign descriptor，名字字段记录的是 **swift_name 之后**的拼写，而且只是最后一截。提案 0023 之前描述符就按这个名字打印，`TypeDatabase` 的归属同步（`registerAttribution(fromAPINotesIndex:)`）因此把改名反查表（`cNamesBySwiftName`）里不带点的 SwiftName spelling 也登进归属表。0023 起描述符按 import info 里的 ABI name 打印（`__C.AGGraphRef`、`__C.NSDecimal`），走第 1、2 条。2026-10-01 用 macOS 27 的 SwiftUICore 实测 `dump`：0023 之前 `__C.Graph` / `__C.Subgraph` 共 107 行，之后为 0。那段登记却不能删：它排在 C 名登记之后，还决定着几个模块的 APINotes 都列出的 C 名归谁。Foundation 与 AppKit 的 APINotes 为了标注 category 方法也列了 `NSObject`，C 名登记是后加载的文件说了算；ObjectiveC 的条目把 `NSObject` 改名为它自己，这个 SwiftName spelling 最后登记，`NSObject` 才回到 ObjectiveC。2026-10-03 试删后，AppKit 的 `--resolve-c-module-names` 输出里 `ObjectiveC.NSObject` 108 行、`ObjectiveC.NSObjectProtocol` 22 行全部变成 `Foundation.…`，于是撤回，并用 `TypeDatabaseMergePriorityTests.renamingEntryKeepsItsModuleAgainstLaterListings` 钉住。

映射内容立场：**宁缺毋滥**——条目错了输出跟着错，公开指引要求每条改名都有头文件级一手证据（重建头文件声明或 OpenGraph 这类文档化项目）。

## 管线分层（每层一个类型，一文件）

| 类型 | 职责 | 关键点 |
|---|---|---|
| `SDKPlatform` / `SDKSettings` | 平台 → SDK 路径、target triple、SDK 版本标识 | `SDKSettings.plist` 的 `Version` + `ProductBuildVersion` 组成缓存目录段；`macCatalyst` 没有自己的 SDK：读 macOS SDK（`xcrunSDKName`），target 是 `ios<SupportedTargets.iosmac.DefaultDeploymentTarget>-macabi`，缓存目录与 macOS 分开；`compilerArguments(for:)` 给 Catalyst 显式补 `-Fsystem <SDK>/System/iOSSupport/System/Library/Frameworks` 与 `-I <SDK>/System/iOSSupport/usr/include`——sourcekitd 按前端调用解析参数，没有替 macabi target 加这些路径的驱动，缺了 UIKit 报 `Could not load module: UIKit` |
| `Subprocess` | `xcrun` / `xcode-select -p` 同步调用 | 非零退出码抛错，不再静默返回空串 |
| `SourceKitLocator` | 在开发者目录里找 sourcekitd | 先试 Xcode 的 `Toolchains/XcodeDefault.xctoolchain/usr/lib/…`，再试 Command Line Tools 的 `usr/lib/…`（没有 `Toolchains` 一层）；两者都是 `sourcekitd.framework/Versions/A/sourcekitd` |
| `TypeIndexingAvailability` | 某平台能不能索引、为什么不能 | 要开发者目录与该平台的 SDK；sourcekitd 可缺（缺了只少模块接口一层） |
| `SourceKitManager` | actor：接口的打开、关闭与并发上限 | **每个打开的接口都用同一个文档名 `editor.close`，生成失败也关**；同时最多生成 `defaultMaximumConcurrentGenerations`（2）个。SourceKitService 为每次 `editor.open.interface` 留一个 `SwiftInterfaceGenContext`（两个 `CompilerInstance`，载入该模块及其导入的全部模块，SDK framework 约 1 GB），只有同名的 `editor.close` 才释放；不关时一个服务进程活多久就攒多久——为 AppKit 的依赖建索引 6 秒到 27 GB，RuntimeViewer 两个服务进程各到 80 GB。请求经 `InterfaceDocumentService` 协议发出，`SourceKitManagerTests` 用替身核对配对与并发；sourcekitd 那一侧是 `SourceKitDInterfaceDocumentService`：dylib 路径经 `SourceKitLocator` 从 active developer dir 派生（不再硬编码 `/Applications/Xcode.app`），substructure 在返回前转成 `InterfaceDeclarationNode` 值树；`importedModuleNames` 是行级 import 扫描 |
| `InterfaceDeclarationNode` | substructure 的值类型投影 | `other` 节点的子树在转换时即丢弃 |
| `InterfaceTypeNameExtractor` | 值树 → fully-qualified 类型名（纯函数） | extension 节点用被扩展类型名（可带点）作限定前缀、自身不入清单——旧 SwiftSyntax 解析器的 extension 嵌套键错误在此结构性消失 |
| `SDKIndexer` | SDK 文件发现（秒级，零 sourcekitd） | `.swiftmodule` 目录 `skipDescendants`；同名模块先到先得（search path 优先级）；`macCatalyst` 先搜 `System/iOSSupport/…` 再搜 macOS 的同名目录 |
| `APINotesFile` / `APINotesIndex` | `.apinotes` 解析与三张名表 | 修复历史 bug：C 名 → Swift 名映射的 `moduleName` 字段曾被写成 swiftName；`register(files:)` 可追加（后写覆盖，补充包优先级的实现点） |
| `SupplementaryAPINotesLoader` | 用户自备补充映射的枚举与解析（提案 0010） | 路径可为文件或目录（目录取浅层 `.apinotes` 按文件名排序）；解析失败逐文件记日志跳过；CLI 侧另有 stderr 预检警告 |
| `ModuleIndexCacheEntry` / `ModuleIndexCache` | per-module JSON 缓存 | 见下节 |
| `ModuleInterfaceIndexer` | 单模块管线：缓存 → 生成 → 提取 → 回写 | 单模块失败记日志返回 `nil`，不作废整轮索引；submodule interface 并入主模块条目（归属永远写顶层模块名）；**任一 submodule 失败则本轮照常返回但不写缓存**（缓存无完整性标记，写了就把缺口固化到 SDK/generator 版本变化为止——review 发现 4）；sourcekitd 调用经 `InterfaceGenerator` 闭包注入缝，缓存纪律可脱离 sourcekitd 单测 |
| `TypeDatabase` | actor：三源合并 + 懒索引 + 查询 | 第一次 `index` 发现 SDK 并登记 API notes，之后每次只补没索引过的模块与依赖；`register(moduleEntries:)` / `register(apiNotesIndex:)` / `register(supplementaryAPINotesFiles:)` / `register(dependencies:)` 四步是 internal，测试经 `@testable import` 直接驱动，合并优先级因此可脱离 sourcekitd 单测；task group 结果按**完成序**到达，注册前经 `entriesInDiscoveryOrder` 重排回 SDK 发现序（后写覆盖 + 完成序 = 同名归属跨两次运行不确定——review 发现 7）；`moduleName(forImagePath:)` 的扩展名剥除循环带不动点守卫（前导点名字如 `.hidden` 是剥除不动点，曾死循环——review 发现 5） |
| `MovedTypeIndex` / `MovedTypeDeclaration` / `PlatformVersion` | 文本 `.swiftinterface` → 搬家记录（纯函数扫描 + 文件挑选） | 只看第 0 列；版本按数值比较、补零（`15` 等于 `15.0`）；见「搬家记录」一节 |
| `DeclaredTypeNameSource` | 依赖 image 的类型名来源（协议） | 本包不读 Mach-O；MachOObjCSection 的 `ObjCDeclaredTypeNames` 实现它。使用方的模块过滤通常取依赖 image 名集合（`TypeDatabase.moduleName(forImagePath:)`：剥全部扩展名 + `libswift` 前缀） |

## 缓存布局

```
<cacheDirectory>/<platform>/<Version>-<ProductBuildVersion>/<module>.json
```

`cacheDirectory` 是调用方传给 `TypeDatabase(platform:cacheDirectory:supplementaryAPINotesURLs:)` 的目录（RuntimeViewer 放在自己的 Caches 下）；不传时是 `~/Library/Application Support/swift-type-indexing/SDKIndexer`。搬家前的 `Application Support/MachOSwiftSection/SDKIndexer` 不再读，也不自动删。

- 条目是**提取产物**（类型名清单 + submodule 名单），不存 interface 全文。
- 按 SDK 精确构建分目录：Xcode 升级换目录，陈旧条目自然失效（历史实现只按 platform 分目录且要求全 SDK 索引完成的标记文件，升级后继续吃旧数据）。
- `generatorVersion` 不匹配的条目按 miss 处理——提取行为变更时把 `ModuleIndexCacheEntry.currentGeneratorVersion` 加一。
- 全部缓存 I/O 是 best-effort：读写失败记日志、走重新生成，不向上抛错。
- 开发者目录里没有 sourcekitd 时只读缓存、不生成（`ModuleInterfaceIndexer` 的生成闭包为 `nil`），整个数据库只记一次日志；API notes 与运行时元数据照常工作。

## 性能形态

- SDK 扫描只做文件发现，秒级；sourcekitd 生成只对**依赖过滤命中的模块**进行（历史实现对全 SDK 数百模块逐个生成、过滤在其后，首次索引小时级——这是该 target 当年被禁用的直接原因）。
- 首个未命中缓存的模块仍要付一次真实生成成本（大模块数秒到数十秒）；同 SDK 下第二次起走缓存。
- SourceKitService 的内存由同时在生成的接口数决定，每个约 1 GB：生成完立即关闭，并发上限 2。量法：`swift-section interface --uses-system-dyld-shared-cache -n AppKit --resolve-c-module-names`，先清空默认缓存目录，按秒采样新起的 SourceKitService 的 RSS。
- ObjC 懒索引把依赖 image 的解析成本压到「前两层查不到」的路径上；`ObjCInterfaceIndexer.prepare()` 解析全部成员 info，对单个大 framework 不算轻——若实测过重，未来方向是在 MachOObjCSection 加 name-only 快速路径。

## 降级行为（0005 事件化纪律的落点）

降级全部走 `@Loggable` + `#log`（subsystem `com.mxiris.type-indexing`）：单模块 interface 生成失败、submodule 失败、`.apinotes` 解析失败、缓存读写失败、依赖 image 读取失败——都是「跳过该项 + 记日志」，绝不让一个模块的失败作废整个数据库。`index` 只在找不到该平台的 SDK 时抛错，由调用方决定怎么报告（MachOSwiftSection 的 `SwiftInterfaceBuilder.prepare()` 用 `.renderingDegraded(source: .extraDataProvider)` 事件兜住）。

## `@Loggable` 的形态约束（本模块特有的坑）

TypeIndexing 的类型都标 `@available(macOS 13.0, *)`（包部署下限是 macOS 10.15）。`@Loggable` 的**直接类型形态**会展开自带 availability 标注的 static stored `logger`，在显式 `@available` 的类型里被 emit-module 拒绝（"cannot be more available than enclosing scope"，单 target 编译只是 warning，整包 emit-module 是 error）。因此本模块一律用 **protocol 形态**：不标 availability 的 `fileprivate protocol XxxLogging {}` + 标 `@available(macOS 13.0, *)` 的 conformance extension。

## 与 MachOSwiftSection 提案 0009 的差异

- **swift-dependencies 未引入**：提案 E 节的依赖清单含 `Dependencies`（历史实现用 `@Dependency` 注入 `SourceKitManager`）。落地改为让测试直接驱动 `TypeDatabase` 的 `register` 步骤，不需要依赖注入框架——少一个依赖。
- **兜底行级解析器未编写**：提案 A′ 允许 substructure 验证失败时退手写解析；scratchpad 探针实测 substructure 完整可用（ObjectiveC / CoreGraphics 两模块，节点带 kind + name + 嵌套 + extension），按提案「二选一定夺」条款只落主路。
- **APINotes 归属注册比历史实现更宽**：历史实现只注册有 `SwiftName` 的实体；现在每个列出的实体（含 `SwiftPrivate`）都注册归属——`__C.X` 的 X 是 C 名，归属正确性与 Swift 侧可见性无关。改名表在搬家时改为按 importer 规则收 `SwiftPrivate`（见「这个模块做什么」下的 APINotes 一条）。

## 已知限制

- 整个 target 是 macOS-only（`#if os(macOS)` 全文件 + 依赖的 `.when(platforms: [.macOS])` 条件），且运行时要求 macOS 13+ 与本机的开发者目录：macOS 与 Mac Catalyst 有 Command Line Tools 即可，iOS 等其他平台要装了对应 SDK 的 Xcode。
- 对本机真实 SDK 的核对在 `SDKIntegrationTests`，默认关闭，`TYPE_INDEXING_SDK_TESTS=1 swift test --filter SDKIntegrationTests` 手动跑（只读 API notes，约 2 秒）；再加 `TYPE_INDEXING_SOURCEKIT_TESTS=1` 会经 sourcekitd 冷生成 Catalyst 的 UIKit 接口，2026-11-23 在公司那台 10 核 Mac Studio 上用了 126 秒——这也是使用方第一次索引 UIKit 的代价。
- Identifier 重写只覆盖类型引用（`printType` 的 nominal 路径）；成员级 SwiftName 改名（selector → Swift 方法名等）不在本案，另立提案。
- 依赖 image 的模块名取自 image 文件名（`libobjc.A.dylib` → `libobjc`），与 Swift module 名在少数 dylib 上不一致；影响仅限私有类型归属的显示名。
- **声明模块完全不在依赖列表里时三层全 miss**：类型只出现在签名 / 元数据、二进制没有对该框架的任何符号引用时，链接器不会记 `LC_LOAD_DYLIB`（探针实测：只声明 `CGContext` 字段而不调 CG 函数，CoreGraphics 就不在依赖里），依赖过滤自然不会索引该模块，`__C.` 原样保留。真实二进制里用一个类型几乎必调它的函数（或至少链 overlay），所以实际影响很小；若将来遇到，可选增强是把过滤集合扩到依赖闭包（传递依赖）。用户自备的补充映射（提案 0010）不受此限：它不参与依赖过滤，条目覆盖到就能解析——SDK 里根本没有模块的私有框架（AttributeGraph）正是靠它。
