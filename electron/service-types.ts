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
