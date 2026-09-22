# inklet macOS 原生端实现审计

审计日期：2026-09-05。对象：`inklet-app/macos` 的当前工作区，包括尚未提交的 Presentation / Widget 改动。

> 同日后续实现：用户随后要求完成 Widget。已新增 small Quick Send、medium Activity、large Virtual Display、独立 Xcode 扩展工程、嵌入打包、深链导航、账户隔离缓存及 App 内 Virtual Display 页。P0-2 的源码/打包缺口已经处理，P0-3 的最新画面查看入口已补；下面保留最初审计快照。大号在线生成仍依赖 P0-1 的后端实现，Developer ID 签名后的系统 Widget 与共享容器验收仍需完成。当前构建和测试说明见 [Widget README](../WidgetExtension/README.md)。

## 结论与版本边界

原生端已经具备真实的账号、设备、内容列表和浮动发送面板，但尚未完成桌面常驻、系统输入入口、可靠发送和 Widget 分发。当前工作区正在把 Auto 从硬件内容管线改成无硬件 Presentation，这条新路径还不能按当前后端代码完成端到端运行。

- App 仓库基线：`d3607f4`，存在未提交修改和未跟踪的 Widget / Presentation 源码。
- 后端仓库基线：`6507e37`，检查时工作区干净。
- 本机 `~/Applications/inklet.app` 仍显示旧的 **Push something**；当前源码显示 **Create a Presentation**。安装版和工作区已有构建的可执行文件 SHA-256 不同，不能将它们视为同一版本。
- 本次只审查和验证，没有修改产品源码，没有发送内容、解绑设备、退出登录或调整设置开关。
- 已实际查看安装版 Home、General、Notifications；Home 能加载真实设备与内容统计。其他行为以源码和后端契约核对为主，未宣称完成在线发送或真机收屏验收。

状态口径：**已实现**表示存在实际实现和调用；**部分实现**表示有可用子路径但未覆盖完整功能；**仅界面**表示控件存在但没有相应执行逻辑；**未实现**表示没有对应入口或代码。下述 P0/P1/P2 是本次建议的处理顺序，不照搬旧设计稿的优先级。

## 一、会阻断新版本主流程的问题

### P0-1：新的 Auto / Presentation API 与后端不匹配

Mac 的 `generatePresentation()` 使用登录会话 JWT 请求 `/api/app/v1/contents`，提交 `output.formats = [scene, png]`、`preset = macos-widget-medium`，并等待 Presentation 的 `ready` 状态。

当前后端代码只有 `/api/sdk/v1` 挂载；它只接受 PAT，拒绝登录会话 JWT。其 `CreateContentRequest` 没有 `output`，Presentation 响应仍是硬件 `image` 模型，而非 Mac 期待的 `renditions` / `scene` / `ready`。因此不能只把 URL 改成 `/api/sdk/v1` 就解决。

这来自未提交的改动：原先 `AppModel.send()` 调用 `uploadBundle()`；现在切到 `generatePresentation()`，旧方法已经没有 UI 调用者。当前工作区默认发送链路需要补齐后端与客户端契约后才能发布。此结论针对当前检出的后端，不等于已经验证线上部署版本。

证据：[发送入口](../Sources/InkletMac/Models/AppModel.swift#L271)、[新 API](../Sources/InkletMac/Services/InkletAPI.swift#L231)、后端路由（`inklet-backend/cmd/server/router.go:198`）、PAT 鉴权（`inklet-backend/internal/sdk/middleware.go:66`）、后端请求模型（`inklet-backend/internal/sdk/content.go:28`）、后端 Presentation 模型（`inklet-backend/internal/sdk/presentation.go:71`）。

### P0-2：Widget 有源码，但没有可安装的扩展产物

已有共享缓存、Widget View、TimelineProvider、App Group entitlement 和 `WidgetBundle` 源文件。但 SwiftPM 中 Widget 只是 library target；构建脚本只打包主可执行文件和资源，没有生成和嵌入 `.appex`。现有 `macos/build/inklet.app` 也没有 `Contents/PlugIns`。

扩展 README 明确要求后续添加 Xcode Widget Extension target。还需要完成 host / extension 的 App Group 签名配置并实际验收共享容器。仅能编译 Widget 源码不等于用户可以在系统里添加 Widget。

此外，Widget 发出 `inklet://presentations/latest`，主 App 没有 URL scheme 声明和相应导航处理，点击 Widget 的链路也未接通。目前仅支持 medium，small / large 未实现；旧稿中的 Quick Send / Activity Widget 也不在这次实现中。

证据：[扩展待接说明](../WidgetExtension/README.md#L3)、[Package](../Package.swift#L17)、[打包脚本](../Scripts/build-app.sh#L32)、[Widget 深链](../Sources/InkletPresentationWidget/InkletPresentationWidget.swift#L56)。

### P0-3：新生成内容缺少 App 内的查看与管理闭环

新 API 的生成结果仅写入一个 `latest.json` / `latest.png`，然后被 `AppModel.send()` 丢弃；成功后关闭发送面板。App 中没有 Presentation 列表、详情、生成预览、下载或切换当前 Widget 内容的入口。

Home 热力图与 Knowledge 仍读取旧 `/api/raw-items`。当前 SDK 使用独立的 `sdk_contents` 数据模型，没有看到将新生成内容补入旧 raw-items 列表的桥接。因此，新 Content 如何进入 Knowledge 和活动统计仍需实现/明确；不能认为发送后的 `loadKnowledge()` 就能自动完成同步。

证据：[生成后处理](../Sources/InkletMac/Models/AppModel.swift#L274)、[缓存](../Sources/InkletPresentationKit/PresentationCache.swift#L41)、[导航入口](../Sources/InkletMac/Views/RootView.swift#L3)、[旧列表读取](../Sources/InkletMac/Models/AppModel.swift#L95)、SDK Content 存储（`inklet-backend/internal/sdk/repository.go:168`）。

## 二、功能覆盖清单

| 功能 | 状态 | 尚缺什么 / 当前限制 |
| --- | --- | --- |
| 密码登录 | 已实现 | 有表单、真实请求、错误显示 |
| Google 登录 | 已实现 | 有 ASWebAuthenticationSession、回调解析和账号读取；本次未重登实测 |
| Apple 登录 | 未实现 | 没有官方按钮、nonce、原生凭据请求和后端兑换 |
| 注册、订阅、API Token | 已实现外链 | 走 Portal，符合旧稿分工，不应算原生页漏做 |
| 会话恢复、401 刷新 | 部分实现 | 有合并并发刷新；断网恢复和退出清理仍有缺陷，见第三部分 |
| Home | 部分实现 | 问候、活动图、设备卡已有；天气没有实现，统计受加载上限约束 |
| 设备列表 / 详情 | 部分实现 | 真实电量、在线状态、预览、重命名、解绑已有；缺持续刷新、历史分页与准确队列展示 |
| 新设备配对 | 已实现手机引导 | NFC 由 iPhone 完成，Mac 刷新接收设备；六位码/摄像头旧方案已废弃 |
| Show Next | 已实现 | 有真实变更请求；侧栏入口吞掉错误，且 Up next 文案不一定对应实际下一项 |
| 从历史重新展示 | 仅 API | `setCurrentPush()` 已写但没有 UI 调用入口 |
| 浮动 Composer | 部分实现 | NSPanel、文本、附件、链接、发送、Esc、Tab/右箭头采纳建议已有 |
| Auto | 开发中且被阻断 | 工作区已改为无硬件 Presentation，见 P0-1；不能再把它理解为自动推硬件 |
| Manual | 部分实现 | 真实设备 + 单图 custom-push；文字只作图片标题，不支持文本/链接/文件的指定设备 AI 排版，也没有时长参数 |
| 全局快捷键 | 已实现 | 可录制、保存、注册、提示冲突；只在登录后激活 |
| 上下文抓取 | 部分实现 | AX、浏览器、Finder、Preview、Photos 有实现；权限引导和抓取时序有缺口 |
| Services | 部分实现 | 文本、URL、文件已处理；原始 image payload 未处理，冷启动与未登录接收未闭环 |
| 普通文本粘贴 | 已实现 | 编辑器原生粘贴可用 |
| 图片/文件粘贴 | 部分实现 | 工具栏 Paste 按钮能解析，编辑器 ⌘V 没有接入同一路径 |
| HUD / Dock 拖放 | 未实现 | 没有将文件、图片、链接转附件的 drop handler 或 Dock 文件打开入口 |
| 草稿 | 部分实现 | 仅复用面板内存保留；退出/重启丢失，无持久化和发送恢复 |
| 菜单栏常驻 | 未实现 | 没有 MenuBarExtra / NSStatusItem，仅 Window + Settings 场景 |
| 开机启动 | 仅界面 | AppStorage toggle，没有 SMAppService 注册/注销 |
| Show in Dock | 仅界面 | 保存布尔值，没有 activation policy 或菜单栏模式实现 |
| 通知 | 仅界面 | 三个开关，无授权、投递、通知重试动作或事件监听；离线项已经注明未接通 |
| 天气 | 仅设置开关 | 无 Home 天气区、WeatherKit、定位、温度单位等实现 |
| 自动更新 | 未实现 | macOS 无 Sparkle / appcast / 更新检查；Electron 的 updater 不会进入原生包 |
| App Intents / 快捷指令 | 未实现 | macOS 无 AppIntent / AppShortcutsProvider |
| Share Extension | 未实现 | Services 与系统分享面板是不同入口；没有分享扩展 target |
| Widget | 部分源码 | 缺扩展工程、打包和深链；见 P0-2 |
| Knowledge | 部分实现 | Organized / Pending + 本地搜索已有；只读行不能打开全文/附件，分页、失败恢复不完整 |
| 深浅色 | 已实现跟随系统 | 动态颜色已有；独立 System / Light / Dark 偏好控件未实现 |
| 关于与帮助 | 部分实现 | 有 Help 外链；没有设计稿的 About 设置页、更新检查、隐私/联系入口集合 |
| 本地笔记同步、Spotlight、专门 Raycast 集成、多账号 | 未实现、后期范围 | 旧稿 P2，不建议阻塞核心版本 |

主要证据：[App 场景](../Sources/InkletMac/InkletMacApp.swift#L18)、[设置开关](../Sources/InkletMac/Views/SettingsView.swift#L23)、[通知设置](../Sources/InkletMac/Views/SettingsView.swift#L114)、[登录](../Sources/InkletMac/Views/LoginView.swift#L20)、[Manual 限制](../Sources/InkletMac/Views/ComposerView.swift#L120)、[粘贴处理](../Sources/InkletMac/Views/ComposerView.swift#L384)、[动态配色](../Sources/InkletMac/Theme/InkletTheme.swift#L9)。

## 三、有实现但尚未收尾的行为问题

### 1. 上下文权限与输入入口

- **P1，权限设置未接入。** `SelectionContext.requestPermission()` 和 `isTrusted` 没有调用者。新用户不授予 Accessibility 时选中文本抓取静默返回 nil，App 内没有状态说明或授权入口。旧设计声称无权限还能合成 ⌘C，不符合当前实现：两条路径都先检查权限。
- **P1，复制回退的目标焦点存在问题。** `captureContext()` 启动异步任务后马上打开并激活面板；回退合成 ⌘C 时没有绑定原始 pid，也没有恢复源 App 焦点，事件可能发给已经获得焦点的 Inklet。源码已确认这种时序，尚未逐个来源 App 做交互复现。
- **P1，过时抓取结果可能覆盖新的建议。** 只检查面板是否可见，没有使用每次唤起的 token 验证；旧抓取晚返回时可能替换新一次的内容。
- **P1，AppleScript 的“2 秒超时”没有真正脱离阻塞工作。** `withTaskGroup` 内执行不可取消的同步 AppleScript，`cancelAll()` 无法保证该子任务及时退出；需要实际限制执行或采用可管理的独立执行机制。
- **P1，Services 原始图片缺失。** plist 声明 `public.image`，receiver 只读 NSURL 和 String；直接图片 bytes 没有解码。图片文件 URL 是已支持的另一条路径。
- **P1，Services 登录生命周期不完整。** 仅登录成功后 install；冷启动投递时没有待登录 payload 队列。退出时又没有卸载 provider，可能继续打开不能发送的 Composer。
- **P2，键盘功能不完整。** ⌘V 图片转附件只存在工具栏按钮路径；没有设计稿的 ⌘⌫ 清空整份草稿。菜单中的创建快捷键固定 ⌘⇧I，不随用户录制的全局快捷键修改；二者当前允许不同。

证据：[权限与复制](../Sources/InkletMac/Services/SelectionContext.swift#L22)、[异步抓取入口](../Sources/InkletMac/Models/AppModel.swift#L330)、[激活窗口](../Sources/InkletMac/Views/ComposerPanel.swift#L19)、[AppleScript 执行](../Sources/InkletMac/Services/AppContext.swift#L290)、[Services 接收](../Sources/InkletMac/Services/ServicesProvider.swift#L40)、[登录时安装](../Sources/InkletMac/InkletMacApp.swift#L80)。

### 2. 发送可靠性与模式覆盖

- **P1，没有完整发送任务模型。** 没有阶段进度、可取消操作、持久化 outbox、断线续传或启动后恢复。新路径等待 Content 及 Presentation 各最多约 120 秒，界面只有省略号。
- **P1，重试可能重复创建。** 每次点击发送重新生成 UUID 幂等键；内容已经创建、但轮询/下载/缓存失败后再次点击会创建另一份。已有 partial upload ticket 重试只能覆盖单次调用中的一个分支。
- **P1，硬件图像发送未跟踪渲染完成。** confirm 返回后立即刷新一次设备/历史，后端此时可能还处于 PREPARE；后续没有轮询，因此界面可能长期停在旧预览。
- **P1，附件校验不足。** 文件选择器接受任意文件，并在主线程直接读完整 Data；没有大小、数量和 MIME 预检。当前后端限制单文件 10 MiB，SDK 限制最多 50 个 assets 并有白名单。大型 PDF 或不支持的文档会先被读入，再到服务端失败。
- **P1，URL 校验过宽。** Add Link 只检查存在 scheme，未限制绝对 HTTP(S) 与凭据等规则，和后端校验不一致。
- **P1，套餐/额度没有形成产品流程。** 只展示 plan 字符串，没有 `/auth/entitlements`、剩余额度、功能禁用提示与对应升级入口。403/429 主要透传消息；后端对 AI 能力和配额已有区分。
- **P2，生成成功与可查看成功混为一体。** PNG 下载/缓存失败直接表现为整次发送失败；没有复用已生成 Presentation 的“重新下载/更新 Widget”。缺 PNG 时又允许写入空图缓存并报告成功。
- **P2，模式语义需整理。** 当前 Manual 是单图直推，接近 Hardcode；没有通用的“指定硬件、AI 排版”路径。`syncTarget()` 在通用入口不会把之前的 Manual 重置成 Auto，因此“Create Presentation”也可能保留上一次硬件模式。

证据：[发送状态](../Sources/InkletMac/Views/ComposerView.swift#L410)、[幂等键](../Sources/InkletMac/Services/InkletAPI.swift#L261)、[文件读取](../Sources/InkletMac/Views/ComposerView.swift#L373)、[链接校验](../Sources/InkletMac/Views/ComposerView.swift#L344)、后端附件规则（`inklet-backend/internal/sdk/assets.go:9`）、[模式同步](../Sources/InkletMac/Views/ComposerView.swift#L84)。

### 3. 设备管理与 Knowledge

- **P1，队列与“当前展示”内容可能标错。** `upNext` 取历史中第一个 QUEUE 或 PREPARE，而历史按最新时间倒序；后端实际取 QUEUE，按优先级降序、创建时间升序。当前预览标题/时间也直接取 `history.first`，没有对齐 `latestPushID`。
- **P1，设备历史只有前 30 条。** API 支持 cursor，DTO 有 `nextCursor` / `hasMore`，Model 丢弃这些字段，界面没有加载更多；更旧的排队条目也可能被漏掉。
- **P1，Knowledge 最多 300 条，并按约 26 周窗口提前停止。** 页面总数和搜索只覆盖本地已加载的片段；高频用户的热力图、streak、总数也可能不完整。
- **P1，标题请求失败后不能正常重试。** item id 加入 `knowledgeDetailTasks` 后一直不移除；失败的 item 仍保持 Loading，刷新时会被去重逻辑跳过。Knowledge 页面首次 task 若早于列表返回，后续也可能只解析首页的前 40 个标题。
- **P1，没有持续同步。** 没有设备状态/处理状态轮询或回到前台的刷新机制。手动刷新存在，不等于实时在线状态或 Pending 自动转 Organized。
- **P1，解绑确认不一致。** 设备详情有系统二次确认，侧栏右键 Unbind 直接发请求。
- **P2，Knowledge 只是列表。** 没有全文/附件详情、打开原链接、下载附件、重新推送、失败项处理。首版“只读”是旧设计的明确范围，编辑/删除不应算 P0；但只读详情仍没有入口。
- **P2，错误反馈不统一。** 侧栏 Show Next 用 `try?`，`reloadDevice()` 也吞掉错误。设备与 Knowledge 并发加载共享一个 `loadError`，设备成功可覆盖另一支的失败提示。
- **P2，配对完成后可能选中错误设备。** Mac 用 `devices.last` 视为新设备，后端设备按创建时间倒序排列，也不是绑定时间顺序；应通过新增 ID 集合识别。

证据：[队列与标题](../Sources/InkletMac/Views/DeviceDetailView.swift#L99)、实际队列排序（`inklet-backend/internal/iot/repository.go:140`）、[历史加载](../Sources/InkletMac/Models/AppModel.swift#L186)、[Knowledge 加载](../Sources/InkletMac/Models/AppModel.swift#L95)、[标题任务](../Sources/InkletMac/Models/AppModel.swift#L142)、[侧栏操作](../Sources/InkletMac/Views/RootView.swift#L98)、[新设备选择](../Sources/InkletMac/Views/PairDisplayView.swift#L57)。

### 4. 会话与本地数据生命周期

- **P1，网络故障可能被当作登录失效。** `restore()` 对 `me()` 失败统一尝试 refresh，再失败就 signOut 清凭据，没有区分网络错误/服务端错误与确定的凭据失效。
- **P1，退出登录清理不完整。** `AppModel.reset()` 没有重置 account、suggestion、composerTarget；Composer 单例仅隐藏、不销毁，内存草稿保留。新 Widget 缓存也没有在 signOut 调用 `clear()` 和刷新 timeline，退出后仍可能展示上一账号内容。
- **P1，旧异步任务缺少账号隔离。** load、preview、title hydration、发送等任务没有统一取消或 session generation 检查；切账号时旧请求晚返回可能重新填入旧数据。
- **P1，发送失败时未统一触发会话失效处理。** 加载路径会调用 `handle()` / invalidate，Composer catch 只显示错误；token 失效后的界面恢复行为不一致。
- **P2，Release 的 Keychain 写失败仍回退到 JSON 文件。** 当前注释称正式版始终使用 Keychain，实际 `save()` 在 Keychain 失败时继续落盘；需要明确正式版失败策略。此次没有读取实际凭据文件。
- **P2，账号套餐不会随常规 Refresh 更新。** 常规刷新只拉设备和 raw-items，account 来自登录/恢复时的 user，网页升级后可能继续显示旧套餐。

证据：[恢复会话](../Sources/InkletMac/Services/InkletAPI.swift#L106)、[重置逻辑](../Sources/InkletMac/Models/AppModel.swift#L44)、[退出登录](../Sources/InkletMac/Services/Session.swift#L88)、[TokenStore fallback](../Sources/InkletMac/Services/TokenStore.swift#L36)。

## 四、已完成的工程基础与尚缺的验收

已经有：SwiftUI / AppKit 原生实现、Swift 6 actor API 层、全局快捷键生命周期处理、内存预览缓存、真实设备接口、动态深浅色、universal 构建配置、Developer ID 签名与 DMG 公证发布脚本。不能把这些统称为“只有 UI”。

仍缺：原生业务逻辑与 API 契约测试、UI 测试、Widget 扩展安装/签名测试、离线恢复与多账号生命周期测试。当前原生测试只有一个 PresentationCache round-trip；CI 原生 job 只做脚本语法检查和 universal build，不执行 `swift test`。Electron 的 Vitest 测试不会覆盖原生 Swift 业务逻辑。

本次验证：

- 当前工作区 **arm64 Debug `swift build` 通过**，包括主 App、PresentationKit、Widget library。
- 两个打包脚本 `bash -n` 通过；没有重新签名、安装或发布。
- `swift test` 在当前仅 Command Line Tools 的环境下失败于 `no such module 'Testing'`。这属于当前测试环境限制，不能报告为产品编译失败，也不能声称完整测试通过。
- 将现有缓存测试的 round-trip 断言用独立 Swift runner 执行，**Scene JSON 与图片字节保存/读取检查通过**；独立运行不替代 Swift Testing / CI 测试套件。
- 本机安装版的 Home 能读取真实数据，General / Notifications 确认存在上述设置项；没有执行发送、解绑、登录切换或权限申请。
- 未完成本次 universal Release 重建、线上新 API 联调、真实硬件收屏、Widget 添加到桌面、发布证书和公证服务验收。

证据：[现有测试](../Tests/InkletPresentationKitTests/PresentationCacheTests.swift#L5)、[CI](../.github/workflows/ci.yml#L29)、[发布流程](../.github/workflows/release.yml#L45)。

## 五、旧设计中不能直接当作欠账的项目

1. **六位码、摄像头扫码配对：** 已由 NFC-only 协议取代，旧 bind/code 明确返回 410。Mac 引导 iPhone 配对合理。
2. **原生注册、支付、API Token 管理：** 旧稿明确外链 Portal，当前符合这一边界。
3. **macOS 14/15 支持：** 旧稿提到 14+，当前 Package、README、plist 一致要求 macOS 26，且使用 Tahoe API。是否扩大兼容范围是产品决策，不能算已经承诺但漏实现。
4. **Obsidian/Logseq、Spotlight、Raycast、多账号、硬件商店：** 属旧稿后期范围；不应与当前主链路缺口同优先级。
5. **Manual 展示时长：** 旧稿将接口列为待定，当前没有端到端支持。先确认产品仍需要此语义，再补接口和 UI。
6. **Firefox 上下文：** 当前明确不支持自动读取 tab；其他应用可通过 Services / 手动粘贴提交，需作为支持范围说明而非假定所有浏览器可用。

证据：NFC 协议（`inklet-backend/docs/api/nfc-v2-protocol.md:7`）、[旧设计分期](../design/index.html#L1404)、[平台要求](../Package.swift#L6)。

## 六、建议实施顺序

1. **先统一发送产品模型和后端契约。** 明确桌面 Presentation、自动硬件推送、指定硬件 AI 推送、单图直推各自的入口；把新 `/api/app/v1` 能力和 Widget 产物做完整后再切默认路径。
2. **完成原生桌面基础。** 菜单栏常驻、开机启动、Dock 模式、自动更新、权限引导、拖放和 ⌘V 附件，移除或补齐无效设置开关。
3. **完成发送与账号可靠性。** 稳定幂等键、持久化任务/草稿、渲染状态跟踪、附件预检、退出清理、错误分类和账号隔离。
4. **完善内容与设备管理。** 分页、正确队列排序、只读详情、重新展示、前台刷新、统计数据口径。
5. **再扩展系统入口。** Apple 登录、App Intents、Share Extension、通知和天气；按真实使用需求决定 P2 集成。

首轮应围绕“入口可用 → 发送成功 → 有地方查看结果 → 重启/断网/切账号不丢失或串数据”验收，不适合用当前页面数量推算完成百分比。
