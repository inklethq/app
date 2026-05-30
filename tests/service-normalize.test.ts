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
