import {
  isolateHistory,
  undo as undoTableChange,
  redo as redoTableChange,
} from "@codemirror/commands";
import { columnMarkup, parseColumns } from "./columns";
import TableDrawer from "./TableDrawer";
import { useEffect, useRef, useState, type ReactNode } from "react";
import * as Dialog from "@radix-ui/react-dialog";
import * as Menu from "@radix-ui/react-dropdown-menu";
import {
  SidebarSimple,
  FileText,
  FolderOpen,
  Plus,
  MagnifyingGlass,
  TextB,
  TextItalic,
  LinkSimple,
  Image,
  Table,
  Columns,
  Code,
  ArrowSquareOut,
  CaretDown,
  FloppyDisk,
  DotsThree,
  TextH,
  Quotes,
  ListBullets,
  ListNumbers,
  X,
  Check,
  ArrowCounterClockwise,
  ArrowClockwise,
} from "@phosphor-icons/react";
import { MarkdownEditor, renderHTML } from "./editor";
import { request, isNative, type DocumentInfo } from "./bridge";
import { parseTable, tablePatches, type TableModel } from "./source";
import { syntaxTree } from "@codemirror/language";

const welcome =
  '# 留一点空间，给想法。\n\n从一个念头开始，把它写清楚。这里是你的 Markdown 写作空间。\n\n## 写作，无需切换思路\n\n输入 **加粗**、*斜体* 或 `行内代码`，排版会自然呈现。点击段落继续编辑，原文始终保留。\n\n> 好的工具，让你把注意力放回内容。\n\n## 整理细节\n\n| 能力 | 方式 |\n| :--- | :--- |\n| 快速格式 | ⌘B · ⌘I · ⌘K |\n| 全文查找 | ⌘F |\n| 源码模式 | ⇧⌘M |\n\n## 写完，分享\n\n```swift\nlet thought = "Write something that matters."\nprint(thought)\n```\n\n保存为 Markdown，或导出为 HTML 与 PDF。\n';
function Tool({
  label,
  children,
  onClick,
  active = false,
}: {
  label: string;
  children: ReactNode;
  onClick?: () => void;
  active?: boolean;
}) {
  return (
    <button
      className={"tool" + (active ? " active" : "")}
      aria-label={label}
      title={label}
      onClick={onClick}
    >
      {children}
    </button>
  );
}
function Modal({
  title,
  description,
  children,
  close,
}: {
  title: string;
  description: string;
  children: ReactNode;
  close: () => void;
}) {
  return (
    <Dialog.Root
      open
      onOpenChange={(v) => {
        if (!v) close();
      }}
    >
      <Dialog.Portal>
        <Dialog.Overlay className="overlay" />
        <Dialog.Content className="dialog">
          <div className="dialog-heading">
            <Dialog.Title>{title}</Dialog.Title>
            <Dialog.Close className="tool" aria-label="关闭">
              <X />
            </Dialog.Close>
          </div>
          <Dialog.Description>{description}</Dialog.Description>
          {children}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
export default function App() {
  const host = useRef<HTMLDivElement>(null),
    editor = useRef<MarkdownEditor | null>(null),
    commandRef = useRef<(s: string) => void>(() => {});
  const [doc, setDoc] = useState<DocumentInfo>({
    text: "",
    name: "未命名.md",
    path: null,
    encoding: "utf8",
    dirty: false,
  });
  const [outline, setOutline] = useState<
      { title: string; level: number; from: number }[]
    >([]),
    [sidebar, setSidebar] = useState(true),
    [source, setSource] = useState(false),
    [count, setCount] = useState(0),
    [empty, setEmpty] = useState(true),
    [active, setActive] = useState(0);
  const tableOwner = useRef<MarkdownEditor | null>(null);
  const [settings, setSettings] = useState(false);
  const [imagePasteMode, setImagePasteMode] = useState("directory");
  const [pageWidth, setPageWidth] = useState("wide");
  const [sidebarWidth, setSidebarWidth] = useState(228);
  const [windowWidth, setWindowWidth] = useState(window.innerWidth);
  const drag = useRef<{ x: number; width: number } | null>(null);
  const maxSidebar = Math.max(180, Math.min(420, windowWidth - 560));
  const visibleSidebarWidth = Math.min(sidebarWidth, maxSidebar);
  const saveSidebarWidth = (width: number) => {
    void request("setSidebarWidth", { width }).catch((e) =>
      setError(e.message),
    );
  };
  useEffect(() => {
    void request<{ sidebarWidth: number }>("getPreferences")
      .then((p) => {
        setSidebarWidth(p.sidebarWidth);
      })
      .catch((e) => setError(e.message));
    const resize = () => setWindowWidth(window.innerWidth);
    const widthChanged = (event: Event) =>
      setPageWidth((event as CustomEvent<string>).detail);
    window.addEventListener("resize", resize);
    window.addEventListener("native:pageWidth", widthChanged);
    return () => {
      window.removeEventListener("resize", resize);
      window.removeEventListener("native:pageWidth", widthChanged);
    };
  }, []);
  const [error, setError] = useState(""),
    [notice, setNotice] = useState(""),
    [busy, setBusy] = useState(false),
    [external, setExternal] = useState(false);
  const [modal, setModal] = useState<"link" | "code" | null>(null),
    [label, setLabel] = useState(""),
    [destination, setDestination] = useState(""),
    [language, setLanguage] = useState("text");
  const target = useRef({ from: 0, to: 0, image: false });
  const [table, setTable] = useState<TableModel | null>(null);
  const tableSync = useRef<{ source: TableModel; current: TableModel } | null>(
    null,
  );
  if (table && tableSync.current?.source !== table)
    tableSync.current = { source: table, current: table };
  const statTimer = useRef<ReturnType<typeof setTimeout> | undefined>(
    undefined,
  );
  const load = (data: DocumentInfo) => {
    if (!host.current) return;
    if (!isNative)
      void request("loadPreview", { text: data.text, name: data.name });
    editor.current?.destroy();
    setDoc(data);
    setPageWidth(data.pageWidth ?? "wide");
    setSource(false);
    setEmpty(!data.text);
    setCount(data.text.length);
    setExternal(false);
    editor.current = new MarkdownEditor(host.current, data.text, {
      change: (patches, raw) => {
        setDoc((d) => (d.dirty ? d : { ...d, dirty: true }));
        setEmpty(raw.length === 0);
        void request<{ dirty: boolean }>("change", { patches })
          .then((meta) =>
            setDoc((d) =>
              d.dirty === meta.dirty ? d : { ...d, dirty: meta.dirty },
            ),
          )
          .catch((e) => setError("修改未同步到文件宿主：" + e.message));
        clearTimeout(statTimer.current);
        statTimer.current = setTimeout(() => setCount(raw.length), 250);
      },
      outline: setOutline,
      command: (name) => commandRef.current(name),
      table: (model) => openTable(model),
      image: (files) => void importImages(files),
    });
    // 仅开发构建提供自动化入口，生产应用不暴露编辑内部状态。
    if (import.meta.env.DEV || window.__VERIFY)
      window.editorAPI = {
        editor: editor.current,
        load,
        command: (s: string) => commandRef.current(s),
        request,
        benchmark: async () => {
          const root = document.createElement("div");
          root.style.cssText =
            "width:900px;height:600px;position:fixed;top:0;left:0;background:white;z-index:1000";
          document.body.append(root);
          const text =
            "# Heading\n\nA paragraph with **bold**, 中文 and `code`.  \n\n```js\nconst x = 42;\n```\n\n".repeat(
              13000,
            );
          let synced: Promise<unknown> = Promise.resolve();
          const start = performance.now();
          const instance = new MarkdownEditor(root, text, {
            change: (patches) => {
              synced = request("change", { patches });
            },
            outline: () => {},
            command: () => {},
            table: () => {},
            image: () => {},
          });
          await new Promise((r) => requestAnimationFrame(r));
          const open = performance.now() - start;
          const samples: number[] = [];
          for (let i = 0; i < 30; i++) {
            const t = performance.now();
            instance.view.dispatch({
              changes: { from: 22, insert: "x" },
              userEvent: "input.type",
            });
            await synced;
            await new Promise((r) => requestAnimationFrame(r));
            samples.push(performance.now() - t);
          }
          instance.destroy();
          root.remove();
          return {
            bytes: new TextEncoder().encode(text).length,
            openMS: open,
            p95InputToFrameMS: samples.sort((a, b) => a - b)[28],
          };
        },
      };
    if (data.recovered) setNotice("已恢复未保存草稿，请检查后保存。");
  };
  const openTable = (model: TableModel) => {
    const ed = editor.current?.active();
    tableOwner.current = ed ?? null;
    if (ed) {
      const selected = ed.view.state.selection.main.head;
      // 使用表格后方的位置保持预览，撤销记录不再沿用文章顶部的旧光标。
      ed.anchorHistory(
        selected >= model.from && selected <= model.to
          ? selected
          : Math.min(
              ed.view.state.doc.length,
              ed.view.state.doc.lineAt(model.to).to + 1,
            ),
      );
    }
    setTable(model);
  };
  async function importImages(files: File[]) {
    const ed = editor.current?.active();
    if (!ed) return;
    try {
      setBusy(true);
      for (const file of files) {
        const bytes = new Uint8Array(await file.arrayBuffer());
        let binary = "";
        for (let i = 0; i < bytes.length; i += 8192)
          binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
        const ref = await request<string | null>("importImage", {
          name: file.name,
          data: btoa(binary),
        });
        if (ref) {
          const s = ed.view.state.selection.main;
          ed.apply([
            {
              from: s.from,
              to: s.to,
              insert:
                "\n![" +
                file.name.replace(/[\[\]]/g, "") +
                "](<" +
                ref +
                ">)\n",
            },
          ]);
        }
      }
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  }
  async function command(name: string) {
    if (name === "settings") {
      try {
        const p = await request<{
          imagePasteMode?: string;
        }>("getPreferences");
        setImagePasteMode(p.imagePasteMode ?? "directory");
        setSettings(true);
      } catch (e) {
        setError((e as Error).message);
      }
      return;
    }
    if (table && !["save", "saveAs", "openExternal"].includes(name)) {
      if (name === "undo" || name === "redo")
        window.dispatchEvent(
          new CustomEvent("table-command", { detail: name }),
        );
      return;
    }

    const ed = ["mode", "exportHTML", "exportPDF", "find"].includes(name)
      ? editor.current
      : editor.current?.active();
    if (!ed) return;
    try {
      if (name === "columns") {
        const selected = ed.view.state.selection.main;
        const markup = columnMarkup([
          ed.view.state.sliceDoc(selected.from, selected.to),
          "",
        ]);
        ed.view.dispatch({
          changes: {
            from: selected.from,
            to: selected.to,
            insert: "\n\n" + markup + "\n\n",
          },
          annotations: isolateHistory.of("full"),
          userEvent: "input.columns",
        });
        ed.jump(selected.from + 2 + parseColumns(markup)[0].columns[0].from);
        return;
      }
      if (name === "new" || name === "open") {
        if (isNative) {
          await request(name);
          return;
        }
        if (name === "new") {
          load({
            text: "",
            name: "未命名.md",
            path: null,
            encoding: "utf8",
            dirty: false,
          });
          return;
        }
        const picker = document.createElement("input");
        picker.type = "file";
        picker.accept = ".md,.markdown,.txt";
        picker.onchange = async () => {
          const f = picker.files?.[0];
          if (f)
            load({
              text: await f.text(),
              name: f.name,
              path: null,
              encoding: "utf8",
              dirty: false,
            });
        };
        picker.click();
        return;
      }
      if (name === "openExternal") {
        if (!isNative) return;
        setBusy(true);
        const meta = await request<Partial<DocumentInfo> | null>(
          "openExternal",
        );
        if (meta) {
          setDoc((d) => ({ ...d, ...meta }));
          setNotice("已在外部应用打开");
        }
        return;
      }
      if (name === "save" || name === "saveAs") {
        setBusy(true);
        const meta = await request<Partial<DocumentInfo> | null>(name);
        if (meta) {
          setDoc((d) => ({ ...d, ...meta }));
          setExternal(false);
          setNotice("文档已保存");
        }
        return;
      }
      if (name === "mode") {
        ed.toggle();
        setSource(ed.sourceMode);
        return;
      }
      if (name === "bold") {
        ed.wrap("**");
        return;
      }
      if (name === "italic") {
        ed.wrap("*");
        return;
      }
      if (name === "strike") {
        ed.wrap("~~");
        return;
      }
      if (name === "inlineCode") {
        ed.wrap("`");
        return;
      }
      if (name === "find") {
        ed.find();
        return;
      }
      if (name === "undo") {
        ed.undo();
        return;
      }
      if (name === "redo") {
        ed.redo();
        return;
      }
      if (/^h[1-6]$/.test(name)) {
        ed.prefix("#".repeat(Number(name[1])) + " ");
        return;
      }
      if (name === "quote" || name === "bullet" || name === "number") {
        ed.prefix(name === "quote" ? "> " : name === "bullet" ? "- " : "1. ");
        return;
      }
      const s = ed.view.state.selection.main;
      if (name === "table") {
        let node = syntaxTree(ed.view.state).resolveInner(s.from, 1);
        while (node.parent && node.name !== "Table") node = node.parent;
        if (node.name === "Table") {
          const model = parseTable(
            ed.view.state.sliceDoc(node.from, node.to),
            node.from,
          );
          if (model) openTable(model);
        } else {
          const text = "| 标题 | 说明 |\n| --- | --- |\n| 内容 | 内容 |";
          ed.apply([{ from: s.from, to: s.to, insert: "\n" + text + "\n" }]);
          const model = parseTable(text, s.from + 1);
          if (model) openTable(model);
        }
        return;
      }
      if (name === "link") {
        let node = syntaxTree(ed.view.state).resolveInner(s.from, 1);
        while (node.parent && !["Link", "Image"].includes(node.name))
          node = node.parent;
        if (["Link", "Image"].includes(node.name)) {
          const text = ed.view.state.sliceDoc(node.from, node.to),
            m = /^!?\[([^\]]*)\]\((.*)\)$/.exec(text);
          target.current = {
            from: node.from,
            to: node.to,
            image: node.name === "Image",
          };
          setLabel(m?.[1] ?? "");
          setDestination((m?.[2] ?? "").replace(/^<|>$/g, ""));
        } else {
          target.current = { from: s.from, to: s.to, image: false };
          setLabel(ed.view.state.sliceDoc(s.from, s.to));
          setDestination("https://");
        }
        setModal("link");
        return;
      }
      if (name === "code") {
        let node = syntaxTree(ed.view.state).resolveInner(s.from, 1);
        while (node.parent && node.name !== "FencedCode") node = node.parent;
        const info =
          node.name === "FencedCode" ? node.getChild("CodeInfo") : null;
        if (node.name === "FencedCode") {
          const mark = node.getChild("CodeMark");
          target.current = {
            from: info?.from ?? mark!.to,
            to: info?.to ?? mark!.to,
            image: true,
          };
          setLanguage(info ? ed.view.state.sliceDoc(info.from, info.to) : "");
        } else {
          target.current = { from: s.from, to: s.to, image: false };
          setLanguage("text");
        }
        setModal("code");
        return;
      }
      if (name === "image") {
        if (isNative) {
          const paths = await request<{ path: string; name: string }[] | null>(
            "chooseImages",
          );
          if (paths) {
            ed.apply([
              {
                from: s.from,
                to: s.to,
                insert:
                  "\n" +
                  paths
                    .map((p) => "![" + p.name + "](<" + p.path + ">)")
                    .join("\n\n") +
                  "\n",
              },
            ]);
          }
        } else {
          const picker = document.createElement("input");
          picker.type = "file";
          picker.accept = "image/*";
          picker.multiple = true;
          picker.onchange = () =>
            void importImages(Array.from(picker.files ?? []));
          picker.click();
        }
        return;
      }
      if (name === "exportHTML" || name === "exportPDF") {
        setBusy(true);
        const fragment = document.createElement("div");
        fragment.innerHTML = renderHTML(ed.view.state.doc.toString());
        for (const img of fragment.querySelectorAll("img")) {
          img.src = await request<string>("imageURL", {
            path: img.getAttribute("src") ?? "",
          });
        }
        const html =
          '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>' +
          doc.name.replace(/[<>&]/g, "") +
          "</title><style>" +
          exportCSS +
          "</style><body><article>" +
          fragment.innerHTML +
          "</article></body></html>";
        const result = await request("export", {
          html,
          format: name === "exportPDF" ? "pdf" : "html",
        });
        if (result) setNotice("导出完成");
        return;
      }
      if (name === "reload") {
        const data = await request<DocumentInfo | null>("reload");
        if (data) load(data);
        return;
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }
  commandRef.current = (name) => void command(name);
  useEffect(() => {
    void request<DocumentInfo>("ready")
      .then(load)
      .catch((e) => setError(e.message));
    const commandEvent = (e: Event) =>
      commandRef.current((e as CustomEvent).detail as string);
    const docEvent = (e: Event) => load((e as CustomEvent).detail);
    const ext = (e: Event) => setExternal(Boolean((e as CustomEvent).detail));
    const meta = (e: Event) =>
      setDoc((d) => ({ ...d, ...(e as CustomEvent).detail }));
    const fail = (e: Event) => setError(String((e as CustomEvent).detail));
    window.addEventListener("native:metadata", meta);
    window.addEventListener("native:error", fail);
    window.addEventListener("native:command", commandEvent);
    window.addEventListener("native:document", docEvent);
    window.addEventListener("native:external", ext);
    return () => {
      editor.current?.destroy();
      clearTimeout(statTimer.current);
      window.removeEventListener("native:metadata", meta);
      window.removeEventListener("native:error", fail);
      window.removeEventListener("native:command", commandEvent);
      window.removeEventListener("native:document", docEvent);
      window.removeEventListener("native:external", ext);
    };
  }, []);
  // 在 CodeMirror 的默认 drop 处理之前接管文件，避免其读取文件文本并插入当前文档。
  useEffect(() => {
    if (!isNative) return;
    const dragOver = (event: DragEvent) => {
      if (event.dataTransfer?.types.includes("Files")) event.preventDefault();
    };
    const drop = (event: DragEvent) => {
      const data = event.dataTransfer;
      if (!data) return;
      const urls = data
        .getData("text/uri-list")
        .split(/\r?\n/)
        .filter((url) => /^file:.*\.(md|markdown|txt)$/i.test(url.trim()))
        .map((url) => url.trim());
      const files = Array.from(data.files).filter((file) =>
        /\.(md|markdown|txt)$/i.test(file.name),
      );
      if (!files.length && !urls.length) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      void request("openDroppedDocuments", { urls }).catch((e) =>
        setError(e.message),
      );
    };
    window.addEventListener("dragover", dragOver, true);
    window.addEventListener("drop", drop, true);
    return () => {
      window.removeEventListener("dragover", dragOver, true);
      window.removeEventListener("drop", drop, true);
    };
  }, []);
  useEffect(() => {
    if (!notice) return;
    const timer = setTimeout(() => setNotice(""), 3500);
    return () => clearTimeout(timer);
  }, [notice]);
  function submitModal(e: React.FormEvent) {
    e.preventDefault();
    const ed = editor.current?.active();
    if (!ed) return;
    const t = target.current;
    if (modal === "link") {
      const path = destination.replace(/>/g, "%3E").replace(/</g, "%3C");
      ed.apply([
        {
          from: t.from,
          to: t.to,
          insert:
            (t.image ? "!" : "") +
            "[" +
            label.replace(/\]/g, "\\]") +
            "](<" +
            path +
            ">)",
        },
      ]);
    } else {
      if (!/^[\w+#.-]*$/.test(language)) {
        setError("语言标识不能包含空格或反引号。");
        return;
      }
      if (t.image) ed.apply([{ from: t.from, to: t.to, insert: language }]);
      else {
        const selected = ed.view.state.sliceDoc(t.from, t.to),
          ticks = "`".repeat(
            Math.max(
              3,
              ...(selected.match(/`+/g) ?? []).map((x) => x.length + 1),
            ),
          );
        ed.apply([
          {
            from: t.from,
            to: t.to,
            insert:
              "\n" + ticks + language + "\n" + selected + "\n" + ticks + "\n",
          },
        ]);
      }
    }
    setModal(null);
  }
  return (
    <div
      className={"app" + (!sidebar ? " sidebar-hidden" : "")}
      data-page-width={pageWidth}
      style={{
        gridTemplateColumns: `${sidebar && windowWidth > 760 ? visibleSidebarWidth : 0}px minmax(0, 1fr)`,
      }}
    >
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-icon">
            <FileText weight="duotone" />
          </span>
          <span>
            Markdown<span className="brand-sub">本地写作空间</span>
          </span>
        </div>
        <div className="sidebar-actions">
          <button onClick={() => void command("new")}>
            <Plus />
            新建文档<kbd>⌘N</kbd>
          </button>
          <button onClick={() => void command("open")}>
            <FolderOpen />
            打开文件<kbd>⌘O</kbd>
          </button>
        </div>
        <div className="outline-title">
          文档大纲<span>{outline.length ? outline.length : ""}</span>
        </div>
        <nav aria-label="文档大纲">
          {outline.length ? (
            outline.map((h, i) => (
              <button
                key={h.from}
                className={"outline-item " + (active === i ? "selected" : "")}
                style={{ paddingLeft: 12 + (h.level - 1) * 16 }}
                onClick={() => {
                  setActive(i);
                  editor.current?.jump(h.from);
                }}
              >
                <span className="heading-level">H{h.level}</span>
                <span>{h.title}</span>
              </button>
            ))
          ) : (
            <p className="outline-empty">
              添加标题后，
              <br />
              在这里浏览文档结构。
            </p>
          )}
        </nav>
        <div className="sidebar-bottom">
          <span className="local-dot" />
          文件保存在本机
          <button
            className="tool"
            aria-label="全局设置"
            onClick={() => void command("settings")}
          >
            设置
          </button>
        </div>
        <div
          className="sidebar-resizer"
          role="separator"
          aria-label="调整文档大纲宽度"
          aria-orientation="vertical"
          aria-valuemin={180}
          aria-valuemax={maxSidebar}
          aria-valuenow={visibleSidebarWidth}
          tabIndex={sidebar ? 0 : -1}
          onPointerDown={(e) => {
            if (e.button !== 0) return;
            e.preventDefault();
            drag.current = { x: e.clientX, width: visibleSidebarWidth };
            e.currentTarget.setPointerCapture(e.pointerId);
          }}
          onPointerMove={(e) => {
            if (!drag.current) return;
            setSidebarWidth(
              Math.round(
                Math.max(
                  180,
                  Math.min(
                    maxSidebar,
                    drag.current.width + e.clientX - drag.current.x,
                  ),
                ),
              ),
            );
          }}
          onPointerUp={(e) => {
            if (!drag.current) return;
            drag.current = null;
            e.currentTarget.releasePointerCapture(e.pointerId);
            saveSidebarWidth(visibleSidebarWidth);
          }}
          onPointerCancel={() => {
            drag.current = null;
            saveSidebarWidth(visibleSidebarWidth);
          }}
          onLostPointerCapture={() => {
            drag.current = null;
          }}
          onDoubleClick={() => {
            setSidebarWidth(228);
            saveSidebarWidth(228);
          }}
          onKeyDown={(e) => {
            const values: Record<string, number> = {
              ArrowLeft: visibleSidebarWidth - 10,
              ArrowRight: visibleSidebarWidth + 10,
              Home: 180,
              End: maxSidebar,
            };
            if (!(e.key in values)) return;
            e.preventDefault();
            const width = Math.max(180, Math.min(maxSidebar, values[e.key]));
            setSidebarWidth(width);
            saveSidebarWidth(width);
          }}
        />
      </aside>
      <main>
        <header className="topbar">
          <Tool
            label={sidebar ? "收起大纲" : "展开大纲"}
            onClick={() => setSidebar(!sidebar)}
          >
            <SidebarSimple />
          </Tool>
          <div className="document-title">
            <span>
              {doc.dirty && <span className="unsaved-dot" />}
              {doc.name}
            </span>
            <small title={doc.path ?? ""}>
              {doc.path
                ? doc.path.split("/").slice(0, -1).join("/")
                : "尚未选择保存位置"}
            </small>
          </div>
          <div className="top-actions">
            <Menu.Root>
              <Menu.Trigger
                className="export-button"
                aria-label="页面宽度"
                title="当前文档的页面宽度"
              >
                {
                  { default: "标准宽度", wide: "较宽（默认）", full: "全宽" }[
                    pageWidth
                  ]
                }
                <CaretDown />
              </Menu.Trigger>
              <Menu.Portal>
                <Menu.Content className="menu" align="end" sideOffset={8}>
                  <Menu.RadioGroup
                    value={pageWidth}
                    onValueChange={(mode) => {
                      void request("setPageWidth", { mode })
                        .then(() => setPageWidth(mode))
                        .catch((e) => setError(e.message));
                    }}
                  >
                    {[
                      ["default", "标准宽度"],
                      ["wide", "较宽（默认）"],
                      ["full", "全宽"],
                    ].map(([value, label]) => (
                      <Menu.RadioItem
                        key={value}
                        value={value}
                        data-page-width-option={value}
                      >
                        {label}
                        <Menu.ItemIndicator className="menu-check">
                          <Check />
                        </Menu.ItemIndicator>
                      </Menu.RadioItem>
                    ))}
                  </Menu.RadioGroup>
                </Menu.Content>
              </Menu.Portal>
            </Menu.Root>
            <button
              className="save-button"
              onClick={() => void command("save")}
              disabled={busy}
            >
              <FloppyDisk />
              {busy ? "处理中" : "保存"}
            </button>
            <Menu.Root>
              <Menu.Trigger className="export-button">
                导出
                <CaretDown />
              </Menu.Trigger>
              <Menu.Portal>
                <Menu.Content className="menu" align="end" sideOffset={8}>
                  <Menu.Item onSelect={() => void command("exportHTML")}>
                    HTML 文档
                    <ArrowSquareOut />
                  </Menu.Item>
                  <Menu.Item onSelect={() => void command("exportPDF")}>
                    PDF 文档
                    <ArrowSquareOut />
                  </Menu.Item>
                </Menu.Content>
              </Menu.Portal>
            </Menu.Root>
          </div>
        </header>
        <div className="formatbar">
          <div className="format-group">
            <Menu.Root>
              <Menu.Trigger className="text-style">
                正文
                <CaretDown />
              </Menu.Trigger>
              <Menu.Portal>
                <Menu.Content className="menu" sideOffset={8}>
                  {[1, 2, 3, 4, 5, 6].map((n) => (
                    <Menu.Item key={n} onSelect={() => void command("h" + n)}>
                      <TextH />
                      标题 {n}
                      <kbd>⌘{n}</kbd>
                    </Menu.Item>
                  ))}
                </Menu.Content>
              </Menu.Portal>
            </Menu.Root>
            <span className="divider" />
            <Tool label="加粗 ⌘B" onClick={() => void command("bold")}>
              <TextB />
            </Tool>
            <Tool label="斜体 ⌘I" onClick={() => void command("italic")}>
              <TextItalic />
            </Tool>
            <Tool label="引用" onClick={() => void command("quote")}>
              <Quotes />
            </Tool>
            <Tool label="无序列表" onClick={() => void command("bullet")}>
              <ListBullets />
            </Tool>
            <Tool label="有序列表" onClick={() => void command("number")}>
              <ListNumbers />
            </Tool>
            <span className="divider" />
            <Tool label="链接 ⌘K" onClick={() => void command("link")}>
              <LinkSimple />
            </Tool>
            <Tool label="插入图片" onClick={() => void command("image")}>
              <Image />
            </Tool>
            <Tool label="插入或编辑表格" onClick={() => void command("table")}>
              <Table />
            </Tool>
            <Tool label="插入分栏" onClick={() => void command("columns")}>
              <Columns />
            </Tool>
            <Tool label="代码块与语言" onClick={() => void command("code")}>
              <Code />
            </Tool>
            <Menu.Root>
              <Menu.Trigger className="tool" aria-label="更多编辑操作">
                <DotsThree />
              </Menu.Trigger>
              <Menu.Portal>
                <Menu.Content className="menu">
                  <Menu.Item onSelect={() => void command("strike")}>
                    删除线
                  </Menu.Item>
                  <Menu.Item onSelect={() => void command("inlineCode")}>
                    行内代码
                  </Menu.Item>
                  <Menu.Separator />
                  <Menu.Item onSelect={() => void command("undo")}>
                    <ArrowCounterClockwise />
                    撤销<kbd>⌘Z</kbd>
                  </Menu.Item>
                  <Menu.Item onSelect={() => void command("redo")}>
                    <ArrowClockwise />
                    重做<kbd>⇧⌘Z</kbd>
                  </Menu.Item>
                  <Menu.Item onSelect={() => void command("saveAs")}>
                    另存为<kbd>⇧⌘S</kbd>
                  </Menu.Item>
                  {isNative && (
                    <Menu.Item
                      disabled={busy}
                      onSelect={() => void command("openExternal")}
                    >
                      外部应用打开…
                      <ArrowSquareOut />
                    </Menu.Item>
                  )}
                </Menu.Content>
              </Menu.Portal>
            </Menu.Root>
          </div>
          <div className="view-group">
            <Tool label="查找与替换 ⌘F" onClick={() => void command("find")}>
              <MagnifyingGlass />
            </Tool>
            <div className="mode-switch" aria-label="编辑模式">
              <button
                className={!source ? "current" : ""}
                onClick={() => {
                  if (source) void command("mode");
                }}
              >
                写作
              </button>
              <button
                className={source ? "current" : ""}
                onClick={() => {
                  if (!source) void command("mode");
                }}
              >
                源码
              </button>
            </div>
          </div>
        </div>
        {external && (
          <div className="conflict-banner">
            磁盘上的文件已变化。保存时将检查冲突。
            <button onClick={() => void command("reload")}>重新载入</button>
          </div>
        )}
        <div className="writing-area">
          <div ref={host} className="editor-host" />
          {empty && (
            <div className="empty-state">
              <FileText weight="thin" />
              <h1>把想法，写下来。</h1>
              <p>点击开始写作，或打开已有的 Markdown 文件。</p>
              <div>
                <button
                  onClick={() => {
                    editor.current?.apply([
                      { from: 0, to: 0, insert: welcome },
                    ]);
                  }}
                >
                  试写一篇示例
                </button>
                <button onClick={() => void command("open")}>
                  打开文件 <span>⌘O</span>
                </button>
              </div>
            </div>
          )}
        </div>
        <footer>
          <span className={doc.dirty ? "" : "saved"}>
            {doc.dirty ? <span className="unsaved-dot" /> : <Check />}
            {doc.dirty ? "未保存" : "已保存"}
            {!doc.path && !doc.dirty ? " · 新文档" : ""}
          </span>
          <span>
            {count.toLocaleString()} 字符<span className="footer-sep">·</span>
            {doc.encoding.toUpperCase()}
            <span className="footer-sep">·</span>Markdown
          </span>
        </footer>
      </main>
      {notice && (
        <div className="toast" role="status">
          <Check />
          {notice}
        </div>
      )}
      {error && (
        <Modal
          title="操作未完成"
          description="你的编辑内容仍保留在窗口中。"
          close={() => setError("")}
        >
          <p className="error-message">{error}</p>
          <div className="dialog-footer">
            <button className="primary" onClick={() => setError("")}>
              知道了
            </button>
          </div>
        </Modal>
      )}
      {modal && (
        <Modal
          title={
            modal === "link"
              ? target.current.image
                ? "编辑图片引用"
                : "编辑链接"
              : "代码块"
          }
          description={
            modal === "link"
              ? "支持网页地址、标题锚点和本地相对路径。"
              : "选择语言以启用语法高亮。代码不会被执行。"
          }
          close={() => setModal(null)}
        >
          <form onSubmit={submitModal}>
            {modal === "link" ? (
              <>
                <label>
                  显示文字
                  <input
                    autoFocus
                    value={label}
                    onChange={(e) => setLabel(e.target.value)}
                  />
                </label>
                <label>
                  地址
                  <input
                    value={destination}
                    onChange={(e) => setDestination(e.target.value)}
                    required
                  />
                </label>
              </>
            ) : (
              <label>
                语言
                <input
                  autoFocus
                  list="languages"
                  value={language}
                  onChange={(e) => setLanguage(e.target.value)}
                />
                <datalist id="languages">
                  {[
                    "text",
                    "javascript",
                    "typescript",
                    "swift",
                    "go",
                    "python",
                    "json",
                    "bash",
                    "rust",
                    "sql",
                  ].map((s) => (
                    <option key={s}>{s}</option>
                  ))}
                </datalist>
              </label>
            )}
            <div className="dialog-footer">
              <button type="button" onClick={() => setModal(null)}>
                取消
              </button>
              <button className="primary" type="submit">
                应用
              </button>
            </div>
          </form>
        </Modal>
      )}
      {settings && (
        <Modal
          title="全局设置"
          description="设置对所有文档生效，自动保存。"
          close={() => setSettings(false)}
        >
          <label className="settings-field">
            图片粘贴方式
            <select
              value={imagePasteMode}
              onChange={(e) => {
                const mode = e.target.value;
                void request("setImagePasteMode", { mode })
                  .then(() => setImagePasteMode(mode))
                  .catch((e) => setError(e.message));
              }}
            >
              <option value="directory">
                保存到 Markdown 文件所在目录（默认）
              </option>
              <option value="base64">内嵌 Base64</option>
            </select>
          </label>
          <p>
            目录方式使用相对路径；Base64
            将图片数据写入文档，无需额外图片文件。插入和拖入图片也使用此设置。
          </p>
        </Modal>
      )}
      {table && (
        <TableDrawer
          table={table}
          close={() => setTable(null)}
          onChange={(rows, aligns, action) => {
            const ed = tableOwner.current;
            const session = tableSync.current;
            if (!ed || !session) return false;
            const current = session.current;
            if (
              ed.view.state.sliceDoc(current.from, current.to) !==
              current.original
            ) {
              setError("正文中的表格已变化，请重新打开表格编辑器。");
              return false;
            }
            const length = ed.view.state.doc.length;
            // 独立事务使表格撤销恢复原始格式，同时不抢走网格输入焦点。
            if (action === "undo") undoTableChange(ed.view);
            else if (action === "redo") redoTableChange(ed.view);
            else
              ed.view.dispatch({
                changes: tablePatches(current, rows, aligns),
                annotations: isolateHistory.of("full"),
                userEvent: "input.table",
              });
            const end = current.to + ed.view.state.doc.length - length;
            session.current = parseTable(
              ed.view.state.sliceDoc(current.from, end),
              current.from,
            )!;
            return true;
          }}
        />
      )}
    </div>
  );
}
const exportCSS = `body{font:16px/1.8 -apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif;color:#25282b;margin:40px auto;max-width:760px;padding:0 24px;overflow-wrap:anywhere}h1,h2,h3{line-height:1.4;break-after:avoid}h1{font-size:32px}h2{font-size:24px}blockquote{margin:24px 0;padding:4px 20px;border-left:3px solid #a5b5ab;color:#596760}pre{background:#f4f5f4;padding:20px;white-space:pre-wrap;border-radius:8px}code{font:13px/1.7 Menlo,monospace}table{border-collapse:collapse;width:100%;margin:24px 0}td,th{border:1px solid #ddd;padding:10px 14px;text-align:left}th{background:#f6f7f6}[align=right]{text-align:right}[align=center]{text-align:center}.columns-render{margin:20px 0}.columns-render>section{min-width:0;overflow-wrap:anywhere}.columns-render table{display:block;overflow:auto}.columns-render pre{overflow:auto}figure{margin:20px 0}figcaption{margin-top:8px;font-size:13px;color:#596760}img{max-width:100%;height:auto}img[align]{display:block;float:none}img[align=center]{margin-inline:auto}img[align=right]{margin-left:auto}a{color:#3c6b54}tr,img{break-inside:avoid}@media print{body{margin:0;max-width:none;padding:0}}`;
