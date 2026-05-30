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
