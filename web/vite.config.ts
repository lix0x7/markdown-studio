import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig({
  base: "./",
  define: {
    "process.env.NODE_ENV": '"production"',
    "process.env.LOG": "undefined",
  },
  plugins: [react()],
  build: {
    target: "safari16",
    outDir: "dist",
    assetsInlineLimit: 1000000,
    cssCodeSplit: false,
    lib: {
      entry: "src/main.tsx",
      name: "MarkdownNative",
      formats: ["iife"],
      fileName: () => "app.js",
    },
  },
  server: { port: 5178, strictPort: true },
});
