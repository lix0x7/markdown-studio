// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from "vitest";

beforeEach(() => {
  vi.resetModules();
  const values = new Map<string, string>();
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
  });
});
afterEach(() => { delete window.webkit; vi.unstubAllGlobals(); });

// 模拟旧原生进程，验证新版前端拖动后的保存和重新读取。
it("stores sidebar preferences when the native host predates the preference API", async () => {
  window.webkit = { messageHandlers: { bridge: { postMessage: (message: any) => {
    window.nativeReply(message.id, null, `不支持的操作：${message.action}`);
  } } } };
  const { request } = await import("../src/bridge");
  expect(await request("getPreferences")).toEqual({ sidebarWidth: 228 });
  await expect(request("setSidebarWidth", { width: 310 })).resolves.toBe(true);
  expect(await request("getPreferences")).toEqual({ sidebarWidth: 310 });
  await expect(request("save")).rejects.toThrow("不支持的操作：save");
});

it("uses native preferences when supported", async () => {
  let width = 228;
  window.webkit = { messageHandlers: { bridge: { postMessage: (message: any) => {
    if (message.action === "setSidebarWidth") width = message.data.width;
    window.nativeReply(message.id, message.action === "getPreferences" ? { sidebarWidth: width } : true);
  } } } };
  const { request } = await import("../src/bridge");
  await request("setSidebarWidth", { width: 320 });
  expect(await request("getPreferences")).toEqual({ sidebarWidth: 320 });
  expect(localStorage.getItem("sidebarWidth")).toBeNull();
});

it("does not hide native preference failures", async () => {
  window.webkit = { messageHandlers: { bridge: { postMessage: (message: any) => {
    window.nativeReply(message.id, null, "侧栏宽度超出范围。");
  } } } };
  const { request } = await import("../src/bridge");
  await expect(request("setSidebarWidth", { width: 500 })).rejects.toThrow("侧栏宽度超出范围。");
});
