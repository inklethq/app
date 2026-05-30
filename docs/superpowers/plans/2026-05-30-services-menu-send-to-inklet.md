# macOS Services 菜单 "Send to Inklet" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户在任意 macOS app 里选中 文本/链接/文件/图片 后,通过右键"服务 → Send to Inklet"把内容送进 Inklet 主窗口并预填,确认后走现有上传流程。

**Architecture:** 主进程内加载一个 Objective-C++ N-API addon,注册一个 `NSApplication` services provider;服务触发时读 `NSPasteboard`,把原始 payload 经 threadsafe function 回调到 JS;`electron/services.ts` 把 payload 归一化为 `ServiceItem[]`(文件字节在主进程读取),经 IPC `service-content` 发到渲染进程;`InputBox.tsx` 复用现有附件逻辑填充输入框。

**Tech Stack:** Electron + React 19 + TypeScript;vitest + @testing-library/react;node-gyp + node-addon-api(原生 addon);electron-builder(NSServices + 打包签名)。

**关于测试边界:** 纯逻辑(归一化、UI 分发)走 TDD + vitest。原生 addon 与打包签名无法单测,走手动验证清单(Task 7)。每个任务都让仓库保持"可运行 + 测试通过"状态。

---

## 文件结构

| 文件 | 责任 | 任务 |
|---|---|---|
| `tests/setup.ts` | vitest jsdom 的 jest-dom matchers 接入 | 1 |
| `electron/service-types.ts` | 共享类型 `ServicePayload` / `ServiceItem`(无第三方 import) | 1 |
| `electron/service-normalize.ts` | 纯函数:`mimeFromPath` + `normalizeServicePayload`(注入 readFile) | 2 |
| `tests/service-normalize.test.ts` | 归一化逻辑单测 | 2 |
| `src/components/InputBox.tsx` | 监听 `service-content`,分发填充输入框 | 3 |
| `tests/InputBox.service.test.tsx` | InputBox 服务分发单测 | 3 |
| `electron/services.ts` | 加载 addon、归一化、show 窗口、发 IPC | 4 |
| `electron/preload.ts` | 暴露 `onServiceContent` | 4 |
| `electron/main.ts` | 启动时 `initServices` | 4 |
| `native/services/binding.gyp` | 原生 addon 构建配置 | 5 |
| `native/services/services.mm` | services provider + pasteboard 读取 | 5 |
| `scripts/build-native.mjs` | 针对 Electron ABI 构建 addon | 5 |
| `electron-builder.yml` | NSServices 声明 + extraResources + beforeBuild | 6 |
| `scripts/before-build.cjs` | 打包时按目标 arch 构建 addon | 6 |

---

## Task 1: 测试基础设施 + 共享类型

**Files:**
- Create: `tests/setup.ts`
- Create: `electron/service-types.ts`

- [ ] **Step 1: 创建测试 setup 文件**

`vitest.config.ts` 已经引用了 `./tests/setup.ts`,但该文件还不存在。创建它以接入 jest-dom 断言:

```ts
// tests/setup.ts
import "@testing-library/jest-dom";
```

- [ ] **Step 2: 创建共享类型**

```ts
// electron/service-types.ts

/** 原生 addon 交给 JS 的原始 payload */
export interface ServicePayload {
  text?: string;
  urls?: string[];           // web URL (http/https)
  files?: string[];          // 绝对文件路径
  images?: { base64: string; mime: string }[]; // 剪贴板/选区里的原始图片
}

/** 归一化后发给渲染进程的条目 */
export type ServiceItem =
  | { kind: "text"; text: string }
  | { kind: "url"; url: string }
  | { kind: "image"; filename: string; contentType: string; sizeBytes: number; base64: string }
  | { kind: "file"; filename: string; contentType: string; sizeBytes: number; base64: string };
```

- [ ] **Step 3: 验证测试仍然干净**

Run: `pnpm test`
Expected: PASS —— 输出 `No test files found, exiting with code 0`(setup 文件存在但还没有测试文件,vitest 不会因 setup 缺失报错)。

- [ ] **Step 4: Commit**

```bash
git add tests/setup.ts electron/service-types.ts
git commit -m "$(cat <<'EOF'
feat(services): add test setup + shared service types

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: 归一化纯函数(TDD)

**Files:**
- Create: `electron/service-normalize.ts`
- Test: `tests/service-normalize.test.ts`

- [ ] **Step 1: 写失败测试**

```ts
// tests/service-normalize.test.ts
import { describe, it, expect } from "vitest";
import { mimeFromPath, normalizeServicePayload } from "../electron/service-normalize";

describe("mimeFromPath", () => {
  it("maps image extensions (case-insensitive)", () => {
    expect(mimeFromPath("/a/b/pic.PNG")).toBe("image/png");
    expect(mimeFromPath("/a/photo.jpg")).toBe("image/jpeg");
  });
  it("maps doc/text extensions", () => {
    expect(mimeFromPath("/a/notes.md")).toBe("text/markdown");
    expect(mimeFromPath("/a/data.csv")).toBe("text/csv");
    expect(mimeFromPath("/a/report.pdf")).toBe("application/pdf");
  });
  it("falls back to octet-stream", () => {
    expect(mimeFromPath("/a/thing.xyz")).toBe("application/octet-stream");
    expect(mimeFromPath("/a/noext")).toBe("application/octet-stream");
  });
});

describe("normalizeServicePayload", () => {
  const readDummy = (p: string) => Buffer.from(`BYTES:${p}`);

  it("passes through text", () => {
    expect(normalizeServicePayload({ text: "hello" }, readDummy))
      .toEqual([{ kind: "text", text: "hello" }]);
  });

  it("passes through web urls", () => {
    expect(normalizeServicePayload({ urls: ["https://x.com"] }, readDummy))
      .toEqual([{ kind: "url", url: "https://x.com" }]);
  });

  it("classifies an image file as an image item with base64", () => {
    const buf = Buffer.from([1, 2, 3]);
    expect(normalizeServicePayload({ files: ["/u/cat.png"] }, () => buf))
      .toEqual([{
        kind: "image", filename: "cat.png", contentType: "image/png",
        sizeBytes: 3, base64: buf.toString("base64"),
      }]);
  });

  it("classifies a text file as a text item (utf8 decoded)", () => {
    expect(normalizeServicePayload({ files: ["/u/notes.md"] }, () => Buffer.from("# Title", "utf8")))
      .toEqual([{ kind: "text", text: "# Title" }]);
  });

  it("classifies other files as generic file attachments", () => {
    const buf = Buffer.from("PDFDATA");
    expect(normalizeServicePayload({ files: ["/u/report.pdf"] }, () => buf))
      .toEqual([{
        kind: "file", filename: "report.pdf", contentType: "application/pdf",
        sizeBytes: buf.length, base64: buf.toString("base64"),
      }]);
  });

  it("passes through pasteboard images with provided mime", () => {
    const items = normalizeServicePayload({ images: [{ base64: "QUJD", mime: "image/png" }] }, readDummy);
    expect(items).toEqual([{
      kind: "image", filename: "Shared.png", contentType: "image/png",
      sizeBytes: Buffer.from("QUJD", "base64").length, base64: "QUJD",
    }]);
  });

  it("skips files that fail to read", () => {
    expect(normalizeServicePayload({ files: ["/missing"] }, () => { throw new Error("ENOENT"); }))
      .toEqual([]);
  });

  it("combines multiple types in order: text, url, image", () => {
    const items = normalizeServicePayload(
      { text: "t", urls: ["https://a"], images: [{ base64: "QQ==", mime: "image/gif" }] },
      readDummy,
    );
    expect(items.map((i) => i.kind)).toEqual(["text", "url", "image"]);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `pnpm exec vitest run tests/service-normalize.test.ts`
Expected: FAIL —— `Failed to resolve import "../electron/service-normalize"` 或 `mimeFromPath is not a function`。

- [ ] **Step 3: 实现 `service-normalize.ts`**

```ts
// electron/service-normalize.ts
import path from "node:path";
import type { ServicePayload, ServiceItem } from "./service-types.js";

const MIME_BY_EXT: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".heic": "image/heic",
  ".bmp": "image/bmp",
  ".tiff": "image/tiff",
  ".txt": "text/plain",
  ".md": "text/markdown",
  ".csv": "text/csv",
  ".json": "application/json",
  ".xml": "application/xml",
  ".html": "text/html",
  ".rtf": "application/rtf",
  ".pdf": "application/pdf",
  ".doc": "application/msword",
  ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ".xls": "application/vnd.ms-excel",
  ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ".ppt": "application/vnd.ms-powerpoint",
  ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
};

// 这些扩展名的文件被并入正文(与 InputBox.handleFile 的文本判定一致)
const TEXT_EXTS = [".txt", ".md", ".csv", ".json", ".xml", ".html", ".rtf"];

const EXT_BY_IMAGE_MIME: Record<string, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/gif": "gif",
  "image/webp": "webp",
  "image/tiff": "tiff",
  "image/heic": "heic",
  "image/bmp": "bmp",
};

export function mimeFromPath(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase();
  return MIME_BY_EXT[ext] ?? "application/octet-stream";
}

export function normalizeServicePayload(
  payload: ServicePayload,
  readFile: (filePath: string) => Buffer,
): ServiceItem[] {
  const items: ServiceItem[] = [];

  if (payload.text) {
    items.push({ kind: "text", text: payload.text });
  }

  for (const url of payload.urls ?? []) {
    items.push({ kind: "url", url });
  }

  for (const filePath of payload.files ?? []) {
    let buf: Buffer;
    try {
      buf = readFile(filePath);
    } catch {
      continue; // 读不了就跳过这个文件
    }
    const filename = path.basename(filePath);
    const contentType = mimeFromPath(filePath);
    const ext = path.extname(filePath).toLowerCase();

    if (contentType.startsWith("image/")) {
      items.push({ kind: "image", filename, contentType, sizeBytes: buf.length, base64: buf.toString("base64") });
    } else if (TEXT_EXTS.includes(ext)) {
      items.push({ kind: "text", text: buf.toString("utf8") });
    } else {
      items.push({ kind: "file", filename, contentType, sizeBytes: buf.length, base64: buf.toString("base64") });
    }
  }

  for (const img of payload.images ?? []) {
    const buf = Buffer.from(img.base64, "base64");
    const ext = EXT_BY_IMAGE_MIME[img.mime] ?? "png";
    items.push({ kind: "image", filename: `Shared.${ext}`, contentType: img.mime, sizeBytes: buf.length, base64: img.base64 });
  }

  return items;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `pnpm exec vitest run tests/service-normalize.test.ts`
Expected: PASS —— `Test Files 1 passed` / `Tests 11 passed`。

- [ ] **Step 5: Commit**

```bash
git add electron/service-normalize.ts tests/service-normalize.test.ts
git commit -m "$(cat <<'EOF'
feat(services): normalize pasteboard payload into ServiceItem[]

Pure logic: extension→mime map and file classification (image/text/doc),
with injected readFile for testability. 11 unit tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: InputBox 接收并分发 service-content(TDD)

**Files:**
- Modify: `src/components/InputBox.tsx`
- Test: `tests/InputBox.service.test.tsx`

- [ ] **Step 1: 写失败测试**

```tsx
// tests/InputBox.service.test.tsx
import { describe, it, expect, beforeEach, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import InputBox from "../src/components/InputBox";
import type { ServiceItem } from "../electron/service-types";

let serviceCb: ((items: ServiceItem[]) => void) | null = null;

beforeEach(() => {
  serviceCb = null;
  (window as any).electronAPI = {
    resizeWindow: vi.fn(),
    onSystemContext: vi.fn(),
    onWindowShown: vi.fn(),
    onServiceContent: (cb: (items: ServiceItem[]) => void) => { serviceCb = cb; },
    fetchOg: vi.fn().mockResolvedValue({
      title: "Example", description: "d", image: null,
      url: "https://example.com", hostname: "example.com",
    }),
  };
});

describe("InputBox service-content", () => {
  it("text item fills the textarea", async () => {
    render(<InputBox />);
    serviceCb!([{ kind: "text", text: "shared note" }]);
    const ta = screen.getByPlaceholderText("Push content to device...") as HTMLTextAreaElement;
    await waitFor(() => expect(ta.value).toBe("shared note"));
  });

  it("url item calls fetchOg and adds a link attachment", async () => {
    render(<InputBox />);
    serviceCb!([{ kind: "url", url: "https://example.com" }]);
    await waitFor(() =>
      expect((window as any).electronAPI.fetchOg).toHaveBeenCalledWith("https://example.com"),
    );
    // 附件在窗口 resize 后 ~200ms 才渲染,放宽超时
    await waitFor(() => expect(screen.getByText("example.com")).toBeInTheDocument(), { timeout: 1500 });
  });

  it("image item adds an image attachment card", async () => {
    render(<InputBox />);
    serviceCb!([{ kind: "image", filename: "cat.png", contentType: "image/png", sizeBytes: 3, base64: "AQID" }]);
    await waitFor(() => expect(screen.getByText("cat.png")).toBeInTheDocument(), { timeout: 1500 });
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `pnpm exec vitest run tests/InputBox.service.test.tsx`
Expected: FAIL —— text 测试里 textarea value 仍为空(尚未实现 onServiceContent 处理)。

- [ ] **Step 3: 在 InputBox 顶部 import 类型**

把 `src/components/InputBox.tsx` 第 2 行:

```tsx
import type { Attachment, OgData } from "../types";
```

改为:

```tsx
import type { Attachment, OgData } from "../types";
import type { ServiceItem } from "../../electron/service-types";
```

- [ ] **Step 4: 新增分发函数 + 注册监听**

在 `src/components/InputBox.tsx` 里,`acceptUrlSuggestion` 函数定义之后、`const canSubmit = ...` 之前,插入分发函数:

```tsx
  function applyServiceItem(item: ServiceItem) {
    if (item.kind === "text") {
      setContent((c) => c + (c ? "\n\n" : "") + item.text);
      setSuggestion("");
      textareaRef.current?.focus();
    } else if (item.kind === "url") {
      acceptUrlSuggestion(item.url);
    } else if (item.kind === "image") {
      addAttachment({
        id: genId(), type: "image", name: item.filename,
        preview: `data:${item.contentType};base64,${item.base64}`,
        fileData: item.base64, contentType: item.contentType, sizeBytes: item.sizeBytes,
      });
    } else {
      addAttachment({
        id: genId(), type: "clipboard", name: item.filename,
        preview: `${item.filename} (${(item.sizeBytes / 1024).toFixed(1)} KB)`,
        fileData: item.base64, contentType: item.contentType, sizeBytes: item.sizeBytes,
      });
    }
  }
```

然后在已有的 `useEffect(() => { ... }, [content]);`(注册 `onSystemContext`/`onWindowShown` 的那个)之后,新增一个只注册一次的 effect:

```tsx
  useEffect(() => {
    (window as any).electronAPI?.onServiceContent?.((items: ServiceItem[]) => {
      for (const item of items) applyServiceItem(item);
    });
    // 注意:沿用现有 on* 监听器风格(无 removeListener)。生产环境 InputBox
    // 只挂载一次,单次注册;StrictMode 开发下会双注册,属已知遗留模式。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
```

- [ ] **Step 5: 跑测试确认通过**

Run: `pnpm exec vitest run tests/InputBox.service.test.tsx`
Expected: PASS —— `Tests 3 passed`。

- [ ] **Step 6: 跑全量测试确保无回归**

Run: `pnpm test`
Expected: PASS —— `Test Files 2 passed` / `Tests 14 passed`。

- [ ] **Step 7: Commit**

```bash
git add src/components/InputBox.tsx tests/InputBox.service.test.tsx
git commit -m "$(cat <<'EOF'
feat(services): InputBox handles service-content (text/url/image/file)

Reuses acceptUrlSuggestion + addAttachment; image preview as data URL.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: 主进程 JS 接线(services.ts + preload + main)

**Files:**
- Create: `electron/services.ts`
- Modify: `electron/preload.ts`
- Modify: `electron/main.ts`

本任务无新单测(原生 addon 尚不存在,加载器优雅降级)。验证标准:`pnpm dev` 启动 app 不崩溃,控制台打印 addon not found 警告。

- [ ] **Step 1: 创建 `electron/services.ts`**

```ts
// electron/services.ts
import { BrowserWindow } from "electron";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { normalizeServicePayload } from "./service-normalize.js";
import type { ServicePayload } from "./service-types.js";

const require = createRequire(import.meta.url);
const __dirname = path.dirname(fileURLToPath(import.meta.url));

interface ServicesAddon {
  register(cb: (payload: ServicePayload) => void): void;
}

function loadAddon(): ServicesAddon | null {
  if (process.platform !== "darwin") return null;
  const candidates = [
    path.join(process.resourcesPath ?? "", "inklet_services.node"),
    path.join(__dirname, "../native/services/build/Release/inklet_services.node"),
  ];
  for (const p of candidates) {
    try {
      if (p && fs.existsSync(p)) return require(p) as ServicesAddon;
    } catch (e) {
      console.error("[services] failed to load addon at", p, e);
    }
  }
  console.warn("[services] native addon not found; Services menu disabled");
  return null;
}

export function initServices(getWindow: () => BrowserWindow | null) {
  const addon = loadAddon();
  if (!addon) return;

  addon.register((payload: ServicePayload) => {
    const items = normalizeServicePayload(payload, (p) => fs.readFileSync(p));
    if (items.length === 0) return;
    const win = getWindow();
    if (!win || win.isDestroyed()) return;
    win.show();
    win.focus();
    const send = () => {
      if (!win.isDestroyed()) win.webContents.send("service-content", items);
    };
    if (win.webContents.isLoading()) {
      win.webContents.once("did-finish-load", send);
    } else {
      send();
    }
  });
}
```

- [ ] **Step 2: 在 preload 暴露 `onServiceContent`**

在 `electron/preload.ts` 的 `onWindowShown` 之后(第 93–95 行那段之后、闭合 `});` 之前)新增:

```ts
  onServiceContent: (cb: (items: unknown[]) => void) => {
    ipcRenderer.on("service-content", (_e, items) => cb(items));
  },
```

- [ ] **Step 3: 在 main 启动时调用 initServices**

在 `electron/main.ts` 第 330 行附近的 import 区(`import { uploadContent } from "./upload.js";` 之后)新增:

```ts
import { initServices } from "./services.js";
```

然后在 `createWindow()` 内、`registerHotkey(currentShortcut);` 之后(约第 128 行)新增一行(尽早注册 provider,避免服务触发时的竞态):

```ts
  initServices(() => win);
```

- [ ] **Step 4: 验证 app 仍能启动**

Run: `pnpm dev`
Expected: app 正常启动;主进程控制台出现 `[services] native addon not found; Services menu disabled`(因为 addon 还没构建)。按 Ctrl-C 退出。

- [ ] **Step 5: 验证测试无回归**

Run: `pnpm test`
Expected: PASS —— `Tests 14 passed`。

- [ ] **Step 6: Commit**

```bash
git add electron/services.ts electron/preload.ts electron/main.ts
git commit -m "$(cat <<'EOF'
feat(services): main-process wiring for Services provider

Loads native addon (graceful no-op if absent), normalizes payload,
shows window and pushes service-content IPC to the renderer.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: 原生 addon(binding.gyp + services.mm + 构建脚本)

**Files:**
- Create: `native/services/binding.gyp`
- Create: `native/services/services.mm`
- Create: `scripts/build-native.mjs`
- Modify: `package.json`(加依赖 + 脚本)

> 这是无法单测的部分,最可能需要在真机上微调。构建针对 **Electron 的 ABI**(而非系统 node),否则主进程 require 时会报 ABI 不匹配。

- [ ] **Step 1: 加依赖**

```bash
pnpm add node-addon-api
pnpm add -D node-gyp
```

如果后续 `node -p "require('node-addon-api').include"` 在 `native/services` 目录下解析失败(pnpm 严格 node_modules),在仓库根加 `.npmrc`:

```
public-hoist-pattern[]=node-addon-api
```

然后重跑 `pnpm install`。

- [ ] **Step 2: 创建 `native/services/binding.gyp`**

```python
{
  "targets": [
    {
      "target_name": "inklet_services",
      "conditions": [
        ["OS=='mac'", {
          "sources": ["services.mm"],
          "include_dirs": ["<!@(node -p \"require('node-addon-api').include\")"],
          "defines": ["NAPI_DISABLE_CPP_EXCEPTIONS"],
          "xcode_settings": {
            "OTHER_CFLAGS": ["-ObjC++", "-std=c++17"],
            "OTHER_LDFLAGS": ["-framework AppKit", "-framework Foundation"],
            "MACOSX_DEPLOYMENT_TARGET": "10.15"
          }
        }]
      ]
    }
  ]
}
```

- [ ] **Step 3: 创建 `native/services/services.mm`**

```objcpp
#include <napi.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <string>
#include <vector>
#include <utility>

static Napi::ThreadSafeFunction g_tsfn;

struct ServiceData {
  std::string text;
  std::vector<std::string> urls;
  std::vector<std::string> files;
  std::vector<std::pair<std::string, std::string>> images; // {base64, mime}
};

@interface InkletServiceProvider : NSObject
- (void)sendToInklet:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error;
@end

@implementation InkletServiceProvider
- (void)sendToInklet:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error {
  ServiceData *data = new ServiceData();

  NSString *str = [pboard stringForType:NSPasteboardTypeString];
  if (str) data->text = std::string([str UTF8String]);

  NSArray *urls = [pboard readObjectsForClasses:@[ [NSURL class] ] options:nil];
  for (NSURL *u in urls) {
    if ([u isFileURL]) {
      if ([u path]) data->files.push_back(std::string([[u path] UTF8String]));
    } else if ([u absoluteString]) {
      data->urls.push_back(std::string([[u absoluteString] UTF8String]));
    }
  }

  if ([NSImage canInitWithPasteboard:pboard]) {
    NSData *png = [pboard dataForType:NSPasteboardTypePNG];
    if (!png) {
      NSData *tiff = [pboard dataForType:NSPasteboardTypeTIFF];
      if (tiff) {
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
        png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      }
    }
    if (png) {
      NSString *b64 = [png base64EncodedStringWithOptions:0];
      data->images.push_back({ std::string([b64 UTF8String]), std::string("image/png") });
    }
  }

  if (g_tsfn) {
    g_tsfn.NonBlockingCall(data, [](Napi::Env env, Napi::Function cb, ServiceData *d) {
      Napi::Object obj = Napi::Object::New(env);
      if (!d->text.empty()) obj.Set("text", Napi::String::New(env, d->text));

      Napi::Array urls = Napi::Array::New(env, d->urls.size());
      for (size_t i = 0; i < d->urls.size(); i++) urls.Set(i, Napi::String::New(env, d->urls[i]));
      obj.Set("urls", urls);

      Napi::Array files = Napi::Array::New(env, d->files.size());
      for (size_t i = 0; i < d->files.size(); i++) files.Set(i, Napi::String::New(env, d->files[i]));
      obj.Set("files", files);

      Napi::Array images = Napi::Array::New(env, d->images.size());
      for (size_t i = 0; i < d->images.size(); i++) {
        Napi::Object im = Napi::Object::New(env);
        im.Set("base64", Napi::String::New(env, d->images[i].first));
        im.Set("mime", Napi::String::New(env, d->images[i].second));
        images.Set(i, im);
      }
      obj.Set("images", images);

      cb.Call({ obj });
      delete d;
    });
  } else {
    delete data;
  }
}
@end

static InkletServiceProvider *g_provider = nil;

Napi::Value Register(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (info.Length() < 1 || !info[0].IsFunction()) {
    Napi::TypeError::New(env, "register(callback) requires a function").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  g_tsfn = Napi::ThreadSafeFunction::New(env, info[0].As<Napi::Function>(), "InkletServices", 0, 1);
  dispatch_async(dispatch_get_main_queue(), ^{
    g_provider = [[InkletServiceProvider alloc] init];
    [NSApp setServicesProvider:g_provider];
    NSUpdateDynamicServices();
    NSLog(@"[inklet] services provider registered");
  });
  return env.Undefined();
}

Napi::Object Init(Napi::Env env, Napi::Object exports) {
  exports.Set("register", Napi::Function::New(env, Register));
  return exports;
}

NODE_API_MODULE(inklet_services, Init)
```

- [ ] **Step 4: 创建构建脚本 `scripts/build-native.mjs`**

```js
// scripts/build-native.mjs —— 针对 Electron ABI 构建原生 addon
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

if (process.platform !== "darwin") {
  console.log("[build-native] non-macOS, skipping");
  process.exit(0);
}

const require = createRequire(import.meta.url);
const electronVer = require("electron/package.json").version;
const nodeGyp = require.resolve("node-gyp/bin/node-gyp.js");
const dir = path.join(__dirname, "../native/services");
const arch = process.env.NATIVE_ARCH || process.arch;

console.log(`[build-native] electron ${electronVer}, arch ${arch}`);
execFileSync(
  process.execPath,
  [
    nodeGyp, "rebuild",
    `--target=${electronVer}`,
    "--dist-url=https://electronjs.org/headers",
    `--arch=${arch}`,
  ],
  { cwd: dir, stdio: "inherit", env: process.env },
);
console.log("[build-native] done");
```

- [ ] **Step 5: 在 package.json 加脚本**

在 `package.json` 的 `scripts` 里新增:

```json
    "build:native": "node scripts/build-native.mjs",
```

- [ ] **Step 6: 构建 addon**

Run: `pnpm build:native`
Expected: 输出 `gyp info ok`,生成 `native/services/build/Release/inklet_services.node`。

排错:若报 `node-addon-api` 找不到,执行 Step 1 的 `.npmrc` 修复并 `pnpm install` 后重试。

- [ ] **Step 7: 在 dev 里冒烟验证 provider 注册**

Run: `pnpm dev`
Expected: 主进程控制台**不再**出现 "addon not found";系统日志/控制台出现 `[inklet] services provider registered`。退出。

- [ ] **Step 8: Commit**

```bash
git add native/services/binding.gyp native/services/services.mm scripts/build-native.mjs package.json pnpm-lock.yaml .npmrc
git commit -m "$(cat <<'EOF'
feat(services): native NSServices provider addon (Obj-C++ N-API)

Reads NSPasteboard (text/url/file/image) and forwards to JS via a
threadsafe function. Built against Electron ABI via build:native.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: electron-builder NSServices 声明 + 打包接线

**Files:**
- Modify: `electron-builder.yml`
- Create: `scripts/before-build.cjs`

> 目标:打包产物里声明服务、`.node` 被复制进 Resources 且被签名、按目标 arch 重建 addon。

- [ ] **Step 1: 在 `electron-builder.yml` 的 `mac:` 块下新增 NSServices 声明**

在 `mac:` 下(与 `category`/`icon` 同级)加:

```yaml
  extendInfo:
    NSServices:
      - NSMenuItem:
          default: "Send to Inklet"
        NSMessage: "sendToInklet"
        NSPortName: "inklet Portal"
        NSSendTypes:
          - "public.utf8-plain-text"
          - "public.url"
          - "public.file-url"
          - "public.image"
```

- [ ] **Step 2: 在 `electron-builder.yml` 顶层新增 extraResources + beforeBuild**

在顶层(与 `files:` 同级)加:

```yaml
extraResources:
  - from: native/services/build/Release/inklet_services.node
    to: inklet_services.node
beforeBuild: ./scripts/before-build.cjs
```

- [ ] **Step 3: 创建 `scripts/before-build.cjs`**

```js
// scripts/before-build.cjs —— electron-builder 打包前按目标 arch 重建原生 addon
const { execFileSync } = require("node:child_process");
const path = require("node:path");

// electron-builder Arch 枚举: ia32=0, x64=1, armv7l=2, arm64=3, universal=4
const ARCH_NAME = { 0: "ia32", 1: "x64", 2: "armv7l", 3: "arm64", 4: "universal" };

module.exports = async function beforeBuild(context) {
  if (process.platform !== "darwin") return true;
  const archName = ARCH_NAME[context.arch] || process.arch;
  console.log(`[before-build] rebuilding native addon for arch ${archName}`);
  execFileSync("node", [path.join(__dirname, "build-native.mjs")], {
    stdio: "inherit",
    env: { ...process.env, NATIVE_ARCH: archName },
  });
  return true; // 继续 electron-builder 默认流程
};
```

- [ ] **Step 4: 打一个本机 arch 的包**

前置:`electron-builder.yml` 配了 `hardenedRuntime` + `notarize: true`,完整出包需要 Developer ID 证书(钥匙串里)和公证凭据(环境变量 `APPLE_ID` / `APPLE_APP_SPECIFIC_PASSWORD` / `APPLE_TEAM_ID`)。**只想本地验证 `.node` 打包与签名**、暂时跳过公证时,可临时把 `notarize` 设为 `false` 跑一次。

Run: `pnpm build && pnpm exec electron-builder --mac --<本机arch>`
（Apple Silicon 用 `--arm64`,Intel 用 `--x64`。）
Expected: 在 `release/` 生成 dmg/zip;构建日志出现 `[before-build] rebuilding native addon`。

> 注:`universal`(4)的原生模块需要 lipo 合并两个 arch,本计划不覆盖;先验证单 arch。双 arch(arm64+x64)分别出包可各自验证。

- [ ] **Step 5: 验证 `.node` 已打入并被签名**

```bash
APP="release/mac-arm64/inklet Portal.app"   # 或 release/mac/... ,按实际路径
ls "$APP/Contents/Resources/inklet_services.node"
codesign -dv --verbose=4 "$APP/Contents/Resources/inklet_services.node"
```
Expected: 文件存在;`codesign` 输出含 `Authority=Developer ID Application: ...`(已签名)。

- [ ] **Step 6: Commit**

```bash
git add electron-builder.yml scripts/before-build.cjs
git commit -m "$(cat <<'EOF'
feat(services): declare NSServices + bundle/sign native addon

extendInfo.NSServices registers "Send to Inklet"; extraResources copies
the .node into Resources; beforeBuild rebuilds it per target arch.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: 手动端到端验证

无代码改动。把签名后的 app 装到 `/Applications` 再验证(Services 需要 `pbs` 注册到已安装的 bundle)。

- [ ] **Step 1: 安装并首启**
  - 把 `release/.../inklet Portal.app` 拖进 `/Applications`,启动一次。
  - 若服务不出现,运行 `pbs -flush`(或注销重登)刷新 Services 缓存。

- [ ] **Step 2: 文本** —— Safari 选中一段文字 → 右键 → 服务 → "Send to Inklet" → 主窗口弹出,正文为该文字。

- [ ] **Step 3: 链接** —— Safari 选中一个超链接 → 服务 → Send to Inklet → 出现链接卡附件(含 OG 标题/hostname)。

- [ ] **Step 4: 图片文件** —— Finder 选中一张 .png/.jpg → 服务 → 图片附件出现。

- [ ] **Step 5: 文档文件** —— Finder 选中一个 .pdf/.docx → 服务 → 文档附件(灰卡 + 文件名)出现。

- [ ] **Step 6: 文本文件并入正文** —— Finder 选中一个 .md/.txt → 服务 → 文件内容并入正文。

- [ ] **Step 7: 隐藏态唤出** —— 设置里开启"关闭到托盘",隐藏窗口后触发服务 → 窗口正确唤出并预填。

- [ ] **Step 8: 上传闭环** —— 任一上述场景点提交 → 现有上传流程正常(绿勾)。

- [ ] **Step 9: 绑定快捷键(可选)** —— 系统设置 → 键盘 → 键盘快捷键 → 服务 → 给 "Send to Inklet" 绑一个快捷键,选中文字后按键直接触发。

- [ ] **Step 10:** 把验证结果(通过/异常)记录到 PR 描述或 spec 末尾。

---

## 完成后

所有任务完成后,用 superpowers:finishing-a-development-branch 决定如何合并 `feat/services-menu-send-to-inklet` 分支。

**已知后续(不在本计划范围):**
- universal(arm64+x64 合一)原生模块的 lipo 合并。
- `pbs` 缓存导致首次服务不显示的更顺滑的引导 UI。
- on* 监听器无 removeListener 的统一治理(全局既有问题)。
