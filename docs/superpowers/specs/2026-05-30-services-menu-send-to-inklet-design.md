# 设计:"发送到 Inklet" macOS Services 菜单

- 日期:2026-05-30
- 状态:已通过设计评审,待写实现计划
- 作者:Kevin Zhong + Claude

## 1. 背景与目标

Inklet Portal 目前只能通过全局快捷键唤起,并用合成 Cmd+C 抓"选中文本"、用 AppleScript 抓"浏览器 URL"。我们要扩展"主动推送"能力:让用户在**任意 app** 里选中内容后,通过 macOS 的**服务(Services)菜单**一键把内容送进 Inklet。

这是"主动分享(push)"交互模型的第一个落地项。相比系统分享面板(Share Extension),Services 菜单**便宜得多**:不需要独立 `.appex`、不需要 App Group、不需要 inside-out 签名——Electron 主进程本身就是真正的 `NSApplication`,可以直接挂 services provider。

**目标:** 任意 app 选中 文本 / 链接 / 文件 / 图片 → 右键"服务 → 发送到 Inklet" → 主窗口弹出,内容直接预填进输入框,用户确认后照常走现有上传流程。

## 2. 范围

**本期做(v1):**
- 注册一个名为 **"Send to Inklet"** 的系统服务,接收四类内容:
  - 选中**文本**(`public.utf8-plain-text`)→ 填入正文
  - 选中**链接 / URL**(`public.url`)→ 抓 OG → 链接卡附件
  - 选中**文件**(`public.file-url`,如 Finder 里选中的文件)→ 文件附件
  - 选中/复制的**图片**(`public.image`,如 Preview、截图)→ 图片附件
- 触发时显示主窗口并预填内容(显式动作,不走幽灵建议)。
- 引导用户(首次)如何让服务出现 + 可选绑定快捷键。

**本期不做(out of scope):**
- 系统分享面板 Share Extension(`.appex`)——留待需求验证后另立项。
- Accessibility API 取选中文本——现有 Cmd+C 已覆盖。
- Obsidian/Logseq 当前笔记 localhost 感知——另立项。
- Windows/Linux(Services 是 macOS 专有;非 macOS 平台此功能不注册,静默跳过)。

## 3. 方案

**采用方案 A:主进程内的原生 N-API addon。**

Electron 没有官方 API 暴露 `NSApplication` 的 services provider(社区 issue #36439 / #8394 至今未实现),因此必须写一个小型 Objective-C++ 原生模块,在主进程里:
1. 实现一个 service provider 对象,方法签名 `- (void)sendToInklet:(NSPasteboard *)pboard userData:(NSString *)data error:(NSString **)error;`
2. 启动时 `[NSApp setServicesProvider:provider]` + `NSUpdateDynamicServices()` 注册。
3. 服务被调用时从 `NSPasteboard` 读取内容,经 `napi_threadsafe_function` 回调到 JS。

放弃的备选:
- **B(独立 helper app)**:多一个 bundle + `inklet://` 间接,moving parts 更多,无收益。
- **C(Automator/Shortcut)**:零原生,但 onboarding 丑、`inklet://` 有 URL 长度限制、文件/图片传不了。仅作"实在不想碰原生"的逃生口,本期不采用。

## 4. 架构与数据流

```
任意 app 选中内容 → 右键 服务 → 发送到 Inklet
      │  (macOS 将 NSPasteboard 交给我们注册的 services provider)
      ▼
native/services/  (新增, Obj-C++ N-API addon)
  · setServicesProvider + NSUpdateDynamicServices
  · 解析 pasteboard:
       text       → string
       web URL    → string
       file URL   → 文件路径 string
       image      → base64 + UTI/mime (NSData 直接编码)
  · 经 threadsafe function 回调 JS,payload:
       { text?, urls?: string[], files?: string[], images?: {base64, mime}[] }
      ▼
electron/services.ts  (新增)
  · 归一化为"渲染进程可直接消费"的形状:
       text  → { kind:'text', text }
       url   → { kind:'url', url }
       file  → 主进程 fs.readFileSync → { kind:'file', filename, contentType, sizeBytes, base64 }
       image → { kind:'image', filename, contentType, sizeBytes, base64 }
    (渲染进程没有 Node,不能读路径,所以文件字节读取放主进程)
  · win.show()/focus();若渲染未就绪则缓存 payload,待就绪后发送
  · 经 IPC 'service-content' 发给渲染进程
      ▼
preload.ts:  暴露 onServiceContent(cb)
      ▼
InputBox.tsx:  监听 'service-content',复用现有逻辑填充输入框
  · text  → setContent(追加)
  · url   → 复用 acceptUrlSuggestion: fetchOg → link 附件
  · image → image 附件 (已有 base64)
  · file  → image/文本/其它,复用 handleFile 的分类逻辑(基于 mime/扩展名)
      ▼
用户确认 → 现有 uploadContent 三步上传(无改动)
```

## 5. 组件详细设计

### 5.1 原生 addon `native/services/`
- 文件:`binding.gyp`、`services.mm`(Objective-C++)。
- 依赖框架:`AppKit`、`Foundation`。
- 导出 N-API 函数:
  - `register(callback)`:保存 threadsafe function;创建并 `setServicesProvider`;`NSUpdateDynamicServices()`。
  - (可选)`flushServices()`:手动触发 `NSUpdateDynamicServices()`,用于安装后刷新。
- provider 方法 `sendToInklet:userData:error:`:
  - `text = [pboard stringForType:NSPasteboardTypeString]`
  - `urls`:`[pboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@NO}]`,区分 `fileURL` 与 web URL;file URL → `path`,web URL → 字符串。
  - `images`:若 `[NSImage canInitWithPasteboard:pboard]`,读 `NSPasteboardTypePNG`/`TIFF` 的 `NSData` → base64 + mime。
  - 组装成 JS 对象经 threadsafe function 回调。
- **线程**:AppKit 在主线程派发服务;仍用 threadsafe function 以与 Node 事件循环安全交互。

### 5.2 `electron/services.ts`(新增)
- `initServices(getWindow: () => BrowserWindow | null)`:仅 `process.platform === 'darwin'` 时加载 addon 并 `register`。
- 回调里:
  - 把 addon 原始 payload 归一化为 `ServiceItem[]`(见数据流);文件用 `fs.readFileSync` + 按扩展名/`mime` 推断 `contentType`。
  - `win.show(); win.focus();`
  - 若 `win.webContents` 未 `did-finish-load`,缓存 payload,监听一次性 ready 事件后再发(避免 IPC 丢失)。
  - `win.webContents.send('service-content', items)`。
- 非 darwin:`initServices` 直接 return,不报错。

### 5.3 preload + IPC 契约
- `preload.ts` 增加:`onServiceContent: (cb: (items: ServiceItem[]) => void) => ipcRenderer.on('service-content', (_e, items) => cb(items))`。
- 复用现有"on* 监听器"风格(注意:与现有一致,本期不引入 removeListener;若 InputBox effect 重订阅造成重复,在实现时用一次性派发或 effect 清理规避)。

### 5.4 `InputBox.tsx` 接收
- 新增 effect 监听 `onServiceContent(items)`,对每个 item 按 `kind` 分发,**复用现有函数**:
  - `text` → `setContent(c => c + (c?'\n\n':'') + item.text)`
  - `url` → 复用 `acceptUrlSuggestion(item.url)`(已有:fetchOg → link 附件,失败回退 hostname)
  - `image` → `addAttachment({type:'image', ...})`(base64 已就绪)
  - `file` → 按 `item.contentType` 走与 `handleFile` 相同的分类:图片→image 附件,文本类→追加正文,其它→`'clipboard'` 附件
- 因为是显式推送,直接填充并聚焦 textarea,不显示为 ghost suggestion。

### 5.5 electron-builder:NSServices 声明 + 签名
- `electron-builder.yml` 增加:
  ```yaml
  mac:
    extendInfo:
      NSServices:
        - NSMenuItem: { default: "Send to Inklet" }
          NSMessage: "sendToInklet"
          NSPortName: "Inklet Portal"
          NSSendTypes:
            - "public.utf8-plain-text"
            - "public.url"
            - "public.file-url"
            - "public.image"
  ```
- 确保原生 `.node` 落入 `app.asar.unpacked` 并被硬化运行时签名 + 公证(electron-builder 默认会签 `.node`,需验证)。

### 5.6 构建管线
- 引入 `node-gyp` 构建 `.mm`。**关键:原生 addon 必须针对 Electron 的 ABI 构建**,使用 `@electron/rebuild`(或 `prebuild --runtime electron --target <ver>`),而非系统 node。
- `vite.config.ts`:把原生 addon 的 `require` 标为 rollup external(与现有 `electron-updater` 同理),不让 vite 试图打包 `.node`。
- `package.json`:加构建脚本(如 `rebuild:native`)并接入打包前流程;仅 macOS 执行。

## 6. 边界情况与风险

1. **`pbs` 缓存**:服务可能要把 app 拖进 `/Applications` 后才出现,或需注销重登 / `pbs -flush`。→ 首次安装写引导文案;提供"刷新服务"动作(`NSUpdateDynamicServices`)。
2. **可见度低**:右键"服务"埋得深。→ 引导用户去"系统设置 → 键盘 → 键盘快捷键 → 服务"绑快捷键。
3. **app 未运行时触发**:macOS 会启动 app 再投递服务请求,存在"provider 尚未注册"的竞态。→ 在 `whenReady` 中**尽早**注册 provider(早于/伴随窗口创建)。
4. **渲染未就绪时 IPC 丢失**:→ `services.ts` 缓存 payload,待 `did-finish-load` 后发送。
5. **Electron 无官方支持**:addon 需长期维护,随 Electron 大版本可能需调整。
6. **大文件**:`fs.readFileSync` + base64 会占内存;v1 先不设上限,但记录为后续 TODO(必要时加大小阈值/提示)。
7. **签名覆盖 `.node`**:若 `.node` 未被正确签名,Gatekeeper 会拦;打包后需验证 `codesign -dv`。

## 7. 测试与验证

- **自动化(vitest)**:
  - `services.ts` 的归一化逻辑(addon 原始 payload → `ServiceItem[]`):纯函数,mock 文件读取,覆盖 text/url/file(图片/文本/其它)/image 各分支。
  - InputBox 的 `service-content` 分发:用 testing-library 渲染,派发各类 item,断言正文/附件状态变化(复用现有附件逻辑)。
- **手动验证清单(原生 + 菜单出现)**:
  1. 打包并把 app 放进 `/Applications`,首次启动。
  2. Safari 选中一段文本 → 右键 服务 → 出现"Send to Inklet" → 点击 → 主窗口弹出,正文填入该文本。
  3. Safari 选中一个链接 / 在地址栏选 URL → 服务 → 链接卡附件出现(含 OG)。
  4. Finder 选中一个图片文件 → 服务 → 图片附件出现。
  5. Finder 选中一个 PDF/docx → 服务 → 文档附件出现。
  6. Preview/截图复制图片后(在支持的上下文)→ 服务 → 图片附件。
  7. app 处于"关闭到托盘"隐藏态时触发 → 窗口正确唤出。
  8. `codesign -dv --verbose=4` 验证 `.node` 已签名;公证通过。

## 8. 验收标准

- 四类内容(文本/链接/文件/图片)均能通过服务菜单送入并正确预填。
- 现有快捷键、浏览器 URL、上传流程不回归。
- 非 macOS 平台构建不报错(功能静默跳过)。
- 打包产物通过签名 + 公证,服务在 `/Applications` 运行时可见。
