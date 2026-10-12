import type { Patch } from "./source";
export type DocumentInfo = {
  text: string;
  name: string;
  path: string | null;
  encoding: string;
  dirty: boolean;
  recovered?: boolean;
};
declare global {
  interface Window {
    webkit?: {
      messageHandlers: { bridge: { postMessage: (message: unknown) => void } };
    };
    nativeReply: (id: number, result: unknown, error?: string) => void;
    nativeEvent: (name: string, data: unknown) => void;
    editorAPI?: any;
    __VERIFY?: boolean;
  }
}
let next = 0;
const pending = new Map<
  number,
  { resolve: (v: any) => void; reject: (e: Error) => void }
>();
window.nativeReply = (id, result, error) => {
  const p = pending.get(id);
  if (!p) return;
  pending.delete(id);
  error ? p.reject(new Error(error)) : p.resolve(result);
};
window.nativeEvent = (name, data) =>
  window.dispatchEvent(new CustomEvent("native:" + name, { detail: data }));
export const isNative = !!window.webkit?.messageHandlers.bridge;
let browserText = "",
  browserName = "未命名.md";
export async function request<T = any>(
  action: string,
  data: Record<string, unknown> = {},
): Promise<T> {
  if (isNative) {
    return new Promise((resolve, reject) => {
      const id = ++next;
      pending.set(id, { resolve, reject });
      window.webkit!.messageHandlers.bridge.postMessage({ id, action, data });
    });
  }
  if (action === "getPreferences")
    return {
      sidebarWidth: Number(localStorage.getItem("sidebarWidth")) || 228,
    } as T;
  if (action === "setSidebarWidth") {
    localStorage.setItem("sidebarWidth", String(data.width));
    return true as T;
  }
  // 浏览器预览只用于开发；文件系统与冲突验收必须使用 macOS 宿主。
  if (action === "loadPreview") {
    browserText = String(data.text);
    browserName = String(data.name);
    return null as T;
  }
  if (action === "ready")
    return {
      text: browserText,
      name: browserName,
      path: null,
      encoding: "utf8",
      dirty: false,
    } as T;
  if (action === "change") {
    for (const p of [...(data.patches as Patch[])].sort(
      (a, b) => b.from - a.from,
    ))
      browserText =
        browserText.slice(0, p.from) + p.insert + browserText.slice(p.to);
    return { dirty: true } as T;
  }
  if (action === "save" || action === "saveAs") {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(
      new Blob([browserText], { type: "text/markdown" }),
    );
    a.download = browserName;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    return { name: browserName, path: null, dirty: false } as T;
  }
  if (action === "imageURL") return data.path as T;
  if (action === "export") {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(
      new Blob([String(data.html)], { type: "text/html" }),
    );
    a.download = "document.html";
    a.click();
    return null as T;
  }
  if (action === "setTitle") {
    browserName = String(data.name);
    return null as T;
  }
  return null as T;
}
