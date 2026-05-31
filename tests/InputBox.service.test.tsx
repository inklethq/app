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
    await waitFor(() => expect(screen.getByText("example.com")).toBeInTheDocument(), { timeout: 1500 });
  });

  it("image item adds an image attachment card", async () => {
    render(<InputBox />);
    serviceCb!([{ kind: "image", filename: "cat.png", contentType: "image/png", sizeBytes: 3, base64: "AQID" }]);
    // attachments render after a ~200ms attachReady delay; 1500ms gives headroom
    await waitFor(() => expect(screen.getByText("cat.png")).toBeInTheDocument(), { timeout: 1500 });
  });

  it("file item adds a generic attachment card", async () => {
    render(<InputBox />);
    serviceCb!([{ kind: "file", filename: "doc.pdf", contentType: "application/pdf", sizeBytes: 2048, base64: "AQID" }]);
    await waitFor(() => expect(screen.getByText("doc.pdf")).toBeInTheDocument(), { timeout: 1500 });
  });
});
