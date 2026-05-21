import { getStoredTokens } from "./auth.js";

const API_URL = "https://api.iminklet.com";

interface UploadAttachment {
  type: "image" | "doc" | "link";
  filename?: string;
  contentType?: string;
  sizeBytes?: number;
  fileData?: string;
  url?: string;
}

interface UploadRequest {
  mainText: string;
  attachments: UploadAttachment[];
  mode: "auto" | "manual";
  deviceId?: string;
  duration?: string;
}

async function authedFetch(path: string, options?: RequestInit): Promise<Response> {
  const { accessToken } = getStoredTokens();
  if (!accessToken) throw new Error("Not authenticated");

  const res = await fetch(`${API_URL}${path}`, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
      ...options?.headers as Record<string, string>,
    },
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`${res.status}: ${body}`);
  }
  return res;
}

async function uploadToS3(presigned: { url: string; fields: Record<string, string> }, fileData: Buffer) {
  const { default: FormData } = await import("node-fetch");

  const boundary = `----inklet${Date.now()}`;
  const parts: Buffer[] = [];

  for (const [key, value] of Object.entries(presigned.fields)) {
    parts.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${key}"\r\n\r\n${value}\r\n`));
  }

  parts.push(Buffer.from(
    `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="upload"\r\nContent-Type: application/octet-stream\r\n\r\n`
  ));
  parts.push(fileData);
  parts.push(Buffer.from(`\r\n--${boundary}--\r\n`));

  const body = Buffer.concat(parts);

  const res = await fetch(presigned.url, {
    method: "POST",
    headers: { "Content-Type": `multipart/form-data; boundary=${boundary}` },
    body,
  });

  if (!res.ok && res.status !== 204) {
    const text = await res.text();
    throw new Error(`S3 upload failed: ${res.status} ${text}`);
  }
}

export async function uploadContent(req: UploadRequest): Promise<{ itemId: string; status: string }> {
  const apiAttachments = req.attachments.map((a) => {
    if (a.type === "link") {
      return { type: "link" as const, url: a.url! };
    }
    return {
      filename: a.filename!,
      contentType: a.contentType!,
      sizeBytes: a.sizeBytes!,
    };
  });

  const uploadRes = await authedFetch("/api/raw-items/upload", {
    method: "POST",
    body: JSON.stringify({
      type: "PORTAL_UPLOAD_BUNDLE",
      mainText: req.mainText,
      attachments: apiAttachments,
    }),
  });

  const uploadData = await uploadRes.json() as {
    itemId: string;
    attachments: Array<{ index: number; url: string; fields: Record<string, string> }>;
    expiresAt: string;
  };

  const fileAttachments = req.attachments.filter((a) => a.type !== "link" && a.fileData);

  for (const presigned of uploadData.attachments) {
    const attachment = fileAttachments[presigned.index] ??
      req.attachments.filter((a) => a.type !== "link")[presigned.index];

    if (!attachment?.fileData) continue;

    const fileBuffer = Buffer.from(attachment.fileData, "base64");
    await uploadToS3(presigned, fileBuffer);
  }

  const confirmRes = await authedFetch(`/api/raw-items/${uploadData.itemId}/confirm`, {
    method: "POST",
  });

  const confirmData = await confirmRes.json() as { itemId: string; status: string };

  console.log(`[upload] itemId=${confirmData.itemId} status=${confirmData.status}`);
  return confirmData;
}
