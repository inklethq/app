export type AttachmentType = "image" | "link" | "clipboard";

export interface OgData {
  title: string;
  description: string;
  image: string | null;
  url: string;
  hostname: string;
}

export interface Attachment {
  id: string;
  type: AttachmentType;
  name: string;
  preview: string;
  url?: string;
  og?: OgData;
  fileData?: string;
  contentType?: string;
  sizeBytes?: number;
}
