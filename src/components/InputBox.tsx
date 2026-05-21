import { useState, useEffect, useRef } from "react";
import type { Attachment, OgData } from "../types";
import AttachmentList from "./AttachmentList";
import LinkModal from "./LinkModal";
import ModeSwitch from "./ModeSwitch";

function genId() {
  return Math.random().toString(36).slice(2);
}

function blobToBase64(blob: Blob): Promise<string> {
  return new Promise((resolve) => {
    const reader = new FileReader();
    reader.onloadend = () => {
      const result = reader.result as string;
      resolve(result.split(",")[1]);
    };
    reader.readAsDataURL(blob);
  });
}

const W = 500;
const H_BASE = 179;
const H_ATTACHMENTS = 80;

const TOOL_SIZE = 30;

function ToolBtn({ onClick, title, children }: { onClick: () => void; title: string; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      title={title}
      style={{
        width: TOOL_SIZE, height: TOOL_SIZE, borderRadius: 8,
        background: "transparent", border: "1px solid var(--border)",
        display: "flex", alignItems: "center", justifyContent: "center",
        color: "var(--text-muted)", cursor: "pointer", padding: 0, flexShrink: 0,
        transition: "background 120ms",
      }}
      onMouseEnter={(e) => e.currentTarget.style.background = "var(--bg)"}
      onMouseLeave={(e) => e.currentTarget.style.background = "transparent"}
    >
      {children}
    </button>
  );
}

export default function InputBox({ disabled, onLoginClick }: { disabled?: boolean; onLoginClick?: (x: number, y: number) => void }) {
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  const [content, setContent] = useState("");
  const [suggestion, setSuggestion] = useState("");
  const [suggestionType, setSuggestionType] = useState<"text" | "url">("text");
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [showLink, setShowLink] = useState(false);
  const [mode, setMode] = useState<"auto" | "manual">("auto");
  const [deviceId, setDeviceId] = useState<string | null>(null);
  const [duration, setDuration] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [submitState, setSubmitState] = useState<"idle" | "loading" | "success">("idle");

  useEffect(() => {
    (window as any).electronAPI?.onSystemContext?.((ctx: { selectedText: string; browserUrl: string }) => {
      if (content) return;
      if (ctx.selectedText) {
        setSuggestion(ctx.selectedText);
        setSuggestionType("text");
      } else if (ctx.browserUrl) {
        setSuggestion(ctx.browserUrl);
        setSuggestionType("url");
      }
    });
    (window as any).electronAPI?.onWindowShown?.(() => {
      setTimeout(() => textareaRef.current?.focus(), 50);
    });
  }, [content]);

  const [attachReady, setAttachReady] = useState(false);
  const prevAttachCount = useRef(0);
  useEffect(() => {
    let h = H_BASE;
    if (attachments.length > 0) h += H_ATTACHMENTS;
    const wasEmpty = prevAttachCount.current === 0;
    prevAttachCount.current = attachments.length;

    (window as any).electronAPI?.resizeWindow(W, h);

    if (attachments.length === 0) {
      setAttachReady(false);
    } else if (wasEmpty) {
      setAttachReady(false);
      setTimeout(() => setAttachReady(true), 200);
    } else {
      setAttachReady(true);
    }
  }, [attachments.length]);

  function addAttachment(a: Attachment) {
    setAttachments((prev) => [...prev, a]);
  }
  function removeAttachment(id: string) {
    setAttachments((prev) => prev.filter((a) => a.id !== id));
  }

  async function handleSubmit() {
    if (!content.trim() && attachments.length === 0) return;
    setSubmitting(true);
    setSubmitState("loading");
    try {
      const uploadAttachments = attachments.map((a) => {
        if (a.type === "link") {
          return { type: "link" as const, url: a.url };
        }
        const mime = a.contentType || "application/octet-stream";
        const isImage = mime.startsWith("image/");
        return {
          type: (isImage ? "image" : "doc") as "image" | "doc",
          filename: a.name,
          contentType: mime,
          sizeBytes: a.sizeBytes || 0,
          fileData: a.fileData,
        };
      });

      await (window as any).electronAPI?.uploadContent({
        mainText: content,
        attachments: uploadAttachments,
        mode,
        deviceId: mode === "manual" ? deviceId : undefined,
        duration: mode === "manual" ? duration : undefined,
      });

      setContent("");
      setSuggestion("");
      setAttachments([]);
      setSubmitState("success");
      setSubmitting(false);
      setTimeout(() => setSubmitState("idle"), 1200);
    } catch (e: any) {
      console.error("Upload failed:", e);
      setSubmitting(false);
      setSubmitState("idle");
    }
  }

  async function handleClipboard() {
    try {
      const items = await navigator.clipboard.read();
      for (const item of items) {
        const imgType = item.types.find((t) => t.startsWith("image/"));
        if (imgType) {
          const blob = await item.getType(imgType);
          const fileData = await blobToBase64(blob);
          addAttachment({
            id: genId(), type: "image",
            name: `Clipboard.${imgType.split("/")[1]}`,
            preview: URL.createObjectURL(blob),
            fileData, contentType: imgType, sizeBytes: blob.size,
          });
          return;
        }
        if (item.types.includes("text/plain")) {
          const blob = await item.getType("text/plain");
          const text = await blob.text();
          setContent((c) => c + text);
          textareaRef.current?.focus();
          return;
        }
      }
    } catch { /* clipboard denied */ }
  }

  async function handleFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;

    const isImage = file.type.startsWith("image/");
    const textExts = [".txt", ".md", ".csv", ".json", ".xml", ".html", ".rtf"];
    const isText = textExts.some((ext) => file.name.toLowerCase().endsWith(ext));

    if (isImage) {
      const fileData = await blobToBase64(file);
      addAttachment({
        id: genId(), type: "image", name: file.name,
        preview: URL.createObjectURL(file),
        fileData, contentType: file.type, sizeBytes: file.size,
      });
    } else if (isText) {
      const reader = new FileReader();
      reader.onload = () => {
        const text = reader.result as string;
        setContent((c) => c + (c ? "\n\n" : "") + text);
        textareaRef.current?.focus();
      };
      reader.readAsText(file);
    } else {
      const fileData = await blobToBase64(file);
      addAttachment({
        id: genId(), type: "clipboard", name: file.name,
        preview: `${file.name} (${(file.size / 1024).toFixed(1)} KB)`,
        fileData, contentType: file.type || "application/octet-stream", sizeBytes: file.size,
      });
    }
    e.target.value = "";
  }

  async function handlePaste(e: React.ClipboardEvent) {
    for (let i = 0; i < e.clipboardData.items.length; i++) {
      const item = e.clipboardData.items[i];
      if (item.type.startsWith("image/")) {
        e.preventDefault();
        const blob = item.getAsFile();
        if (!blob) continue;
        const fileData = await blobToBase64(blob);
        addAttachment({
          id: genId(), type: "image",
          name: `Pasted.${item.type.split("/")[1]}`,
          preview: URL.createObjectURL(blob),
          fileData, contentType: item.type, sizeBytes: blob.size,
        });
        return;
      }
    }
  }

  function handleLinkSubmit(og: OgData) {
    addAttachment({ id: genId(), type: "link", name: og.hostname, preview: og.url, url: og.url, og });
    setShowLink(false);
  }

  async function acceptUrlSuggestion(url: string) {
    try {
      const og: OgData = await (window as any).electronAPI.fetchOg(url);
      addAttachment({ id: genId(), type: "link", name: og.hostname, preview: og.url, url: og.url, og });
    } catch {
      const hostname = new URL(url).hostname;
      addAttachment({ id: genId(), type: "link", name: hostname, preview: url, url });
    }
  }

  const canSubmit = !submitting && (content.trim().length > 0 || attachments.length > 0);

  return (
    <>
      {/* Input box — fixed size, no attachments inside */}
      <div style={{
        background: "var(--bg-input)", border: "1px solid var(--border)",
        borderRadius: 12, display: "flex", flexDirection: "column",
        flexShrink: 0, position: "relative",
      }}>
        {disabled && (
          <div
            onClick={(e) => {
              if (onLoginClick) {
                const sx = window.screenX || 0;
                const sy = window.screenY || 0;
                onLoginClick(sx + e.clientX, sy + e.clientY);
              }
            }}
            style={{
              position: "absolute", inset: 0, borderRadius: 12, zIndex: 10,
              background: "rgba(245,243,237,0.85)",
              display: "flex", alignItems: "center", justifyContent: "center",
              cursor: "pointer",
            }}
          >
            <span style={{ fontSize: 13, color: "var(--text-muted)" }}>
              <span
                style={{ color: "var(--text-secondary)", textDecoration: "underline", cursor: "pointer" }}
              >Login</span>
              {" "}to continue
            </span>
          </div>
        )}
        <div style={{ padding: "12px 14px 0", minHeight: 0, position: "relative" }}>
          {/* Ghost suggestion text */}
          {!content && suggestion && (
            <div style={{
              position: "absolute", top: 12, left: 14, right: 14,
              fontSize: 14, lineHeight: 1.5, color: "var(--text-muted)",
              opacity: 0.5, pointerEvents: "none",
              overflow: "hidden", whiteSpace: "pre-wrap" as const,
              wordBreak: "break-word" as const,
            }}>
              {suggestion}
              <span style={{
                display: "inline-flex", alignItems: "center", justifyContent: "center",
                background: "var(--border)", borderRadius: 4,
                padding: "1px 5px", marginLeft: 6,
                fontSize: 10, color: "var(--text-muted)", opacity: 1,
                verticalAlign: "middle", fontFamily: "var(--font-sans)",
              }}>Tab</span>
            </div>
          )}
          <textarea
            ref={textareaRef}
            value={content}
            onChange={(e) => { setContent(e.target.value); if (e.target.value) setSuggestion(""); }}
            onKeyDown={(e) => {
              if (e.key === "Tab") e.preventDefault();
              if ((e.key === "Tab" || e.key === "ArrowRight") && !content && suggestion) {
                e.preventDefault();
                if (suggestionType === "url") {
                  acceptUrlSuggestion(suggestion);
                } else {
                  setContent(suggestion);
                }
                setSuggestion("");
              } else if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                handleSubmit();
              } else if (e.key === "Escape" && suggestion) {
                setSuggestion("");
              }
            }}
            onPaste={handlePaste}
            placeholder={suggestion ? "" : "Push content to device..."}
            rows={3}
            style={{
              width: "100%", background: "transparent",
              border: "none", outline: "none", resize: "none",
              fontSize: 14, lineHeight: 1.5, color: "var(--text)",
              padding: 0, margin: 0, position: "relative", zIndex: 1,
            }}
          />
        </div>

        <div style={{
          padding: "6px 10px 8px",
          display: "flex", alignItems: "center", justifyContent: "space-between",
          flexShrink: 0,
        }}>
          <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
            <ToolBtn onClick={() => fileRef.current?.click()} title="Upload image">
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                <path d="M7 2.5v6M4.5 5L7 2.5 9.5 5" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round"/>
                <path d="M2.5 11h9" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round"/>
              </svg>
            </ToolBtn>
            <input ref={fileRef} type="file" accept="image/*,.pdf,.txt,.md,.csv,.json,.xml,.html,.rtf,.doc,.docx,.xls,.xlsx,.ppt,.pptx" style={{ display: "none" }} onChange={handleFile} />

            <ToolBtn onClick={handleClipboard} title="Paste from clipboard">
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                <rect x="3.5" y="3.5" width="7" height="8" rx="1.5" stroke="currentColor" strokeWidth="1.2"/>
                <path d="M5.5 3.5V2.5a1 1 0 0 1 3 0v1" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round"/>
              </svg>
            </ToolBtn>

            <ToolBtn onClick={() => setShowLink(true)} title="Add link">
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                <path d="M6 8a3 3 0 0 0 4.24 0l1.42-1.42a3 3 0 0 0-4.24-4.24L7 2.76" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round"/>
                <path d="M8 6a3 3 0 0 0-4.24 0L2.34 7.42a3 3 0 0 0 4.24 4.24L7 11.24" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round"/>
              </svg>
            </ToolBtn>
          </div>

          <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
            <ModeSwitch mode={mode} deviceId={deviceId} duration={duration} onModeChange={setMode} onDeviceChange={setDeviceId} onDurationChange={setDuration} />
            <button
              onClick={handleSubmit}
              disabled={!canSubmit || submitState !== "idle"}
              style={{
                width: 30, height: 30, borderRadius: 8,
                background: submitState === "success" ? "#34A853" : "var(--accent)",
                border: "none",
                display: "flex", alignItems: "center", justifyContent: "center",
                color: submitState === "success" ? "white" : "var(--bg)",
                cursor: canSubmit && submitState === "idle" ? "pointer" : "default",
                opacity: canSubmit || submitState !== "idle" ? 1 : 0.25,
                transition: "background 200ms, opacity 150ms",
                flexShrink: 0,
              }}
            >
              {submitState === "loading" ? (
                <svg width="14" height="14" viewBox="0 0 14 14" fill="none" style={{ animation: "spin 600ms linear infinite" }}>
                  <circle cx="7" cy="7" r="5.5" stroke="currentColor" strokeWidth="1.5" opacity="0.25"/>
                  <path d="M12.5 7a5.5 5.5 0 0 0-5.5-5.5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"/>
                </svg>
              ) : submitState === "success" ? (
                <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                  <path d="M3 7.5l3 3 5-6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"
                    strokeDasharray="15" strokeDashoffset="15" style={{ animation: "checkDraw 400ms ease-out forwards" }}/>
                </svg>
              ) : (
                <svg width="13" height="13" viewBox="0 0 13 13" fill="none">
                  <path d="M6.5 11V2M3.5 5L6.5 2l3 3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              )}
            </button>
          </div>
        </div>
      </div>

      {/* Attachments — wait for window resize on first add */}
      {attachReady && attachments.length > 0 && (
        <div style={{
          paddingTop: 8,
          overflowX: "auto",
          overflowY: "hidden",
          scrollbarWidth: "thin",
          scrollbarColor: "var(--border) transparent",
        }}>
          <AttachmentList attachments={attachments} onRemove={removeAttachment} />
        </div>
      )}

      {showLink && <LinkModal onClose={() => setShowLink(false)} onSubmit={handleLinkSubmit} />}
    </>
  );
}
