import {
  EditorState,
  StateField,
  StateEffect,
  Compartment,
  type Extension,
  type Range,
} from "@codemirror/state";
import {
  EditorView,
  Decoration,
  WidgetType,
  ViewPlugin,
  keymap,
  dropCursor,
  type DecorationSet,
} from "@codemirror/view";
import {
  history,
  historyKeymap,
  defaultKeymap,
  indentWithTab,
  undo,
  redo,
  invertedEffects,
} from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { python } from "@codemirror/lang-python";
import { StreamLanguage } from "@codemirror/language";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { go } from "@codemirror/legacy-modes/mode/go";
import {
  syntaxTree,
  syntaxHighlighting,
  defaultHighlightStyle,
  bracketMatching,
} from "@codemirror/language";
import {
  search,
  searchKeymap,
  highlightSelectionMatches,
  openSearchPanel,
} from "@codemirror/search";
import { marked } from "marked";
import DOMPurify from "dompurify";
import {
  SourceBuffer,
  parseTable,
  type Patch,
  type TableModel,
} from "./source";
import { request } from "./bridge";

export const mode = new Compartment();
const viewport = StateEffect.define<{ from: number; to: number }>();
export const renderHTML = (text: string) =>
  DOMPurify.sanitize(
    marked.parse(text, { async: false, gfm: true }) as string,
    { FORBID_TAGS: ["style", "script", "iframe"], FORBID_ATTR: ["style"] },
  );
class BlockWidget extends WidgetType {
  constructor(
    readonly text: string,
    readonly kind: string,
    readonly from: number,
  ) {
    super();
  }
  eq(other: BlockWidget) {
    return (
      other.text === this.text &&
      other.kind === this.kind &&
      other.from === this.from
    );
  }
  toDOM(view: EditorView) {
    const el = document.createElement("div");
    el.className = "md-widget md-" + this.kind;
    el.innerHTML = renderHTML(this.text);
    if (this.kind === "table") {
      const button = document.createElement("button");
      button.className = "table-edit";
      button.textContent = "编辑表格";
      button.setAttribute("aria-label", "编辑此表格");
      el.prepend(button);
      button.onclick = () =>
        view.dom.dispatchEvent(
          new CustomEvent("edit-table", {
            bubbles: true,
            detail: parseTable(this.text, this.from),
          }),
        );
      el.querySelector("table")?.addEventListener("dblclick", () =>
        button.click(),
      );
    }
    el.querySelectorAll("img").forEach((img) => {
      const path = img.getAttribute("src") ?? "";
      img.removeAttribute("src");
      img.alt = img.alt || "图片";
      request<string>("imageURL", { path })
        .then((url) => {
          img.src = url;
          img.onload = () => view.requestMeasure();
        })
        .catch(() => {
          el.classList.add("image-error");
          img.alt = "图片不可用：" + path;
        });
    });
    if (this.kind === "image") {
      const button = document.createElement("button");
      button.className = "image-edit";
      button.textContent = "编辑图片引用";
      button.onclick = () => {
        view.dispatch({ selection: { anchor: this.from + 1 } });
        view.focus();
      };
      el.append(button);
    }
    return el;
  }
  ignoreEvent() {
    return true;
  }
}
// 只装饰视口附近的语法树节点；源码始终由 CodeMirror 文本模型持有。
function buildDecorations(
  state: EditorState,
  range: { from: number; to: number },
): DecorationSet {
  const out: Range<Decoration>[] = [];
  const seen = new Set<string>();
  const active = state.selection.main;
  const first = state.doc.lineAt(active.from).from,
    last = state.doc.lineAt(active.to).to;
  const editing = (from: number, to: number) => from <= last && to >= first;
  const line = (at: number, cls: string) => {
    const p = state.doc.lineAt(at).from,
      key = p + cls;
    if (!seen.has(key)) {
      seen.add(key);
      out.push(Decoration.line({ class: cls }).range(p));
    }
  };
  const mark = (from: number, to: number, cls: string) => {
    if (to > from) out.push(Decoration.mark({ class: cls }).range(from, to));
  };
  const hide = (from: number, to: number) => {
    if (to > from) out.push(Decoration.replace({}).range(from, to));
  };
  syntaxTree(state).iterate({
    from: range.from,
    to: Math.min(range.to, state.doc.length),
    enter(n) {
      const name = n.name,
        from = n.from,
        to = n.to;
      if (name === "Table") {
        if (!editing(from, to)) {
          out.push(
            Decoration.replace({
              widget: new BlockWidget(state.sliceDoc(from, to), "table", from),
              block: true,
            }).range(from, to),
          );
          return false;
        }
        for (
          let i = state.doc.lineAt(Math.max(from, range.from)).number;
          i <=
          state.doc.lineAt(Math.min(to, range.to, state.doc.length)).number;
          i++
        )
          line(state.doc.line(i).from, "md-table-source");
        return false;
      }
      if (name === "Image") {
        const l = state.doc.lineAt(from);
        if (!editing(from, to) && l.from === from && l.to === to) {
          out.push(
            Decoration.replace({
              widget: new BlockWidget(state.sliceDoc(from, to), "image", from),
              block: true,
            }).range(from, to),
          );
          return false;
        }
      }
      if (/^ATXHeading[1-6]$/.test(name)) {
        line(from, "md-heading md-h" + name.slice(-1));
      }
      if (name === "Blockquote") {
        for (
          let i = state.doc.lineAt(Math.max(from, range.from)).number;
          i <=
          state.doc.lineAt(Math.min(to, range.to, state.doc.length)).number;
          i++
        )
          line(state.doc.line(i).from, "md-quote");
      }
      if (name === "FencedCode") {
        for (
          let i = state.doc.lineAt(Math.max(from, range.from)).number;
          i <=
          state.doc.lineAt(Math.min(to, range.to, state.doc.length)).number;
          i++
        )
          line(state.doc.line(i).from, "md-code-line");
      }
      if (name === "HorizontalRule" && !editing(from, to)) {
        line(from, "md-rule");
        mark(from, to, "md-invisible");
        return false;
      }
      if (name === "StrongEmphasis") mark(from, to, "md-strong");
      if (name === "Emphasis") mark(from, to, "md-em");
      if (name === "Strikethrough") mark(from, to, "md-strike");
      if (name === "InlineCode") mark(from, to, "md-inline-code");
      if (name === "Link") mark(from, to, "md-link");
      if (
        [
          "HeaderMark",
          "EmphasisMark",
          "StrikethroughMark",
          "CodeMark",
          "QuoteMark",
        ].includes(name) &&
        !editing(from, to)
      ) {
        // 围栏保留为轻量语言标记，隐藏行内符号不改变文本坐标。
        if (n.node.parent?.name !== "FencedCode") hide(from, to);
        else mark(from, to, "md-fence-mark");
      }
      if (name === "Link" && !editing(from, to)) {
        const source = state.sliceDoc(from, to);
        const m = /^\[([^\]]+)\]\((.+)\)$/.exec(source);
        if (m) {
          hide(from, from + 1);
          hide(from + 1 + m[1].length, to);
        }
        return false;
      }
    },
  });
  return Decoration.set(out, true);
}
const previewField = StateField.define<{
  range: { from: number; to: number };
  decorations: DecorationSet;
}>({
  create(state) {
    const range = { from: 0, to: 8000 };
    return { range, decorations: buildDecorations(state, range) };
  },
  update(value, tr) {
    let range = value.range;
    for (const e of tr.effects) if (e.is(viewport)) range = e.value;
    if (
      tr.docChanged ||
      tr.selection ||
      range !== value.range ||
      syntaxTree(tr.startState) !== syntaxTree(tr.state)
    )
      return { range, decorations: buildDecorations(tr.state, range) };
    return value;
  },
  provide: (f) => EditorView.decorations.from(f, (v) => v.decorations),
});
const previewViewport = ViewPlugin.fromClass(
  class {
    timer = 0;
    constructor(view: EditorView) {
      this.schedule(view);
    }
    update(u: any) {
      if (u.viewportChanged) this.schedule(u.view);
    }
    schedule(view: EditorView) {
      cancelAnimationFrame(this.timer);
      this.timer = requestAnimationFrame(() => {
        const from = Math.max(0, view.viewport.from - 1000),
          to = Math.min(view.state.doc.length, view.viewport.to + 1000);
        view.dispatch({ effects: viewport.of({ from, to }) });
      });
    }
    destroy() {
      cancelAnimationFrame(this.timer);
    }
  },
);
const preview: Extension = [previewField, previewViewport];
const restoreEndings = StateEffect.define<string[]>();
// 撤销历史保存换行元数据，让混合 CRLF/LF 的跨行删除也可精确恢复。
const endingsField = StateField.define<string[]>({
  create: () => [],
  update(value, tr) {
    for (const e of tr.effects) if (e.is(restoreEndings)) return e.value;
    return value;
  },
});
export type EditorCallbacks = {
  change: (patches: Patch[], raw: string) => void;
  outline: (items: { title: string; level: number; from: number }[]) => void;
  command: (name: string) => void;
  table: (model: TableModel) => void;
  image: (files: File[]) => void;
};
export class MarkdownEditor {
  view: EditorView;
  buffer: SourceBuffer;
  sourceMode = false;
  headings: { title: string; level: number; from: number }[] = [];
  outlineTimer: ReturnType<typeof setTimeout> | undefined;
  constructor(
    parent: HTMLElement,
    raw: string,
    readonly callbacks: EditorCallbacks,
  ) {
    this.buffer = new SourceBuffer(raw);
    this.view = new EditorView({
      parent,
      state: EditorState.create({
        doc: this.buffer.normalized(),
        extensions: [
          EditorState.phrases.of({
            Find: "查找",
            Replace: "替换",
            next: "下一个",
            previous: "上一个",
            all: "全选匹配",
            "match case": "区分大小写",
            regexp: "正则表达式",
            "by word": "全词匹配",
            replace: "替换",
            "replace all": "全部替换",
            close: "关闭",
            "No matches": "没有匹配项",
          }),
          history(),
          // 使用浏览器原生选区，避免独立选区层被代码块背景遮住。
          dropCursor(),
          bracketMatching(),
          highlightSelectionMatches(),
          search({ top: true }),
          markdown({
            base: markdownLanguage,
            codeLanguages: (info) => {
              const lang = info.toLowerCase();
              if (["js", "javascript", "ts", "typescript"].includes(lang))
                return javascript({
                  typescript: lang === "ts" || lang === "typescript",
                }).language;
              if (lang === "json") return json().language;
              if (["py", "python"].includes(lang)) return python().language;
              if (lang === "swift") return StreamLanguage.define(swift);
              if (lang === "go") return StreamLanguage.define(go);
              return null;
            },
            pasteURLAsLink: false,
          }),
          syntaxHighlighting(defaultHighlightStyle),
          endingsField.init(() => this.buffer.endings),
          invertedEffects.of((tr) =>
            tr.docChanged
              ? [restoreEndings.of(tr.startState.field(endingsField))]
              : [],
          ),
          EditorState.transactionExtender.of((tr) => {
            if (!tr.docChanged || tr.effects.some((e) => e.is(restoreEndings)))
              return null;
            const prev = tr.startState.field(endingsField);
            let result = [...prev];
            const changes: { a: number; b: number; count: number }[] = [];
            tr.changes.iterChanges((a, b, _c, _d, insert) => {
              changes.push({
                a: tr.startState.doc.lineAt(a).number - 1,
                b: tr.startState.doc.lineAt(b).number - 1,
                count: insert.lines - 1,
              });
            });
            for (const c of changes.reverse())
              result.splice(
                c.a,
                c.b - c.a,
                ...Array(c.count).fill(this.buffer.preferred),
              );
            return { effects: restoreEndings.of(result) };
          }),
          keymap.of([
            {
              key: "Mod-s",
              run: () => {
                callbacks.command("save");
                return true;
              },
            },
            {
              key: "Mod-Shift-s",
              run: () => {
                callbacks.command("saveAs");
                return true;
              },
            },
            { key: "Mod-b", run: () => this.wrap("**") },
            { key: "Mod-i", run: () => this.wrap("*") },
            {
              key: "Mod-k",
              run: () => {
                callbacks.command("link");
                return true;
              },
            },
            {
              key: "Mod-Shift-m",
              run: () => {
                callbacks.command("mode");
                return true;
              },
            },
            ...Array.from({ length: 6 }, (_, i) => ({
              key: "Mod-" + (i + 1),
              run: () => this.prefix("#".repeat(i + 1) + " "),
            })),
            ...searchKeymap,
            ...historyKeymap,
            ...defaultKeymap,
            indentWithTab,
          ]),
          EditorView.lineWrapping,
          EditorView.contentAttributes.of({
            "aria-label": "Markdown 编辑区",
            spellcheck: "false",
            autocapitalize: "off",
          }),
          mode.of(preview),
          EditorView.updateListener.of((u) => {
            if (u.docChanged) {
              for (const tr of u.transactions)
                if (tr.docChanged) {
                  const changes: Patch[] = [];
                  tr.changes.iterChanges((a, b, _c, _d, s) =>
                    changes.push({ from: a, to: b, insert: s.toString() }),
                  );
                  const patches = this.buffer.apply(
                    changes,
                    tr.state.field(endingsField),
                  );
                  callbacks.change(patches, this.buffer.raw);
                }
              clearTimeout(this.outlineTimer);
              this.outlineTimer = setTimeout(() => this.outline(), 180);
            }
          }),
          EditorView.domEventHandlers({
            dblclick: (event, view) => {
              if (
                event.button !== 0 ||
                event.metaKey ||
                event.ctrlKey ||
                event.altKey ||
                event.shiftKey
              )
                return false;
              const target = event.target as HTMLElement;
              if (
                !view.scrollDOM.contains(target) ||
                target.closest(".md-widget, .cm-gutters, button, a, input")
              )
                return false;
              const content = view.contentDOM.getBoundingClientRect();
              if (event.clientX < content.left || event.clientX > content.right)
                return false;
              // 只接管文字之外的空白；实际字符上的双击继续交给 CodeMirror 选词。
              const lineDOM = target.closest(".cm-line");
              if (lineDOM) {
                const walker = document.createTreeWalker(
                  lineDOM,
                  NodeFilter.SHOW_TEXT,
                );
                const range = document.createRange();
                for (
                  let node = walker.nextNode();
                  node;
                  node = walker.nextNode()
                ) {
                  range.selectNodeContents(node);
                  for (const rect of range.getClientRects()) {
                    if (
                      event.clientX >= rect.left &&
                      event.clientX <= rect.right &&
                      event.clientY >= rect.top &&
                      event.clientY <= rect.bottom
                    )
                      return false;
                  }
                }
              }
              const pos = view.posAtCoords(
                { x: event.clientX, y: event.clientY },
                false,
              );
              if (pos === null) return false;
              const line = view.state.doc.lineAt(pos);
              const first = view.coordsAtPos(0),
                last = view.coordsAtPos(view.state.doc.length);
              let at = line.to,
                count = 1,
                anchor = at + 1;
              if (first && event.clientY < first.top) {
                at = 0;
                anchor = 0;
              } else if (last && event.clientY > last.bottom) {
                at = view.state.doc.length;
                count = Math.max(
                  1,
                  Math.ceil(
                    (event.clientY - last.bottom) / view.defaultLineHeight,
                  ),
                );
                anchor = at + count;
              }
              event.preventDefault();
              view.dispatch({
                changes: { from: at, insert: "\n".repeat(count) },
                selection: { anchor },
                userEvent: "input",
                scrollIntoView: true,
              });
              view.focus();
              return true;
            },
            paste: (event) => {
              const files = Array.from(event.clipboardData?.files ?? []).filter(
                (f) => f.type.startsWith("image/"),
              );
              if (files.length) {
                event.preventDefault();
                callbacks.image(files);
                return true;
              }
              return false;
            },
            drop: (event, view) => {
              const files = Array.from(event.dataTransfer?.files ?? []).filter(
                (f) => f.type.startsWith("image/"),
              );
              if (files.length) {
                event.preventDefault();
                const pos = view.posAtCoords({
                  x: event.clientX,
                  y: event.clientY,
                });
                if (pos !== null) view.dispatch({ selection: { anchor: pos } });
                callbacks.image(files);
                return true;
              }
              return false;
            },
          }),
        ],
      }),
    });
    this.view.dom.addEventListener("edit-table", (event) =>
      callbacks.table((event as CustomEvent).detail),
    );
    this.view.dom.addEventListener("click", (event) => {
      const mouse = event as MouseEvent;
      if (!(mouse.metaKey || mouse.ctrlKey)) return;
      const pos = this.view.posAtCoords({ x: mouse.clientX, y: mouse.clientY });
      if (pos === null) return;
      let node = syntaxTree(this.view.state).resolveInner(pos, 1);
      while (node.parent && node.name !== "Link") node = node.parent;
      if (node.name === "Link") {
        const m = /\]\((.*)\)$/.exec(
          this.view.state.sliceDoc(node.from, node.to),
        );
        if (m) {
          const path = m[1].replace(/^<|>$/g, "");
          if (path.startsWith("#")) {
            let anchor = path.slice(1);
            try {
              anchor = decodeURIComponent(anchor);
            } catch {}
            const seen = new Map<string, number>();
            for (const h of this.headings) {
              const base = h.title
                .toLowerCase()
                .replace(/[^\p{L}\p{N}_\s-]/gu, "")
                .trim()
                .replace(/\s+/g, "-");
              const count = seen.get(base) ?? 0;
              seen.set(base, count + 1);
              if (anchor === (count ? base + "-" + count : base)) {
                this.jump(h.from);
                break;
              }
            }
          } else
            void request("openLink", { path }).catch((e) =>
              window.nativeEvent("error", e.message),
            );
        }
      }
    });
    this.outline();
  }
  outline() {
    const items: { title: string; level: number; from: number }[] = [];
    let fence = "",
      offset = 0;
    // 大纲在输入停止后扫描文本，避免等待视口之外的后台语法解析。
    for (const text of this.view.state.doc.toString().split("\n")) {
      const marker = /^ {0,3}(`{3,}|~{3,})/.exec(text)?.[1];
      if (marker) {
        if (!fence) fence = marker;
        else if (
          marker[0] === fence[0] &&
          marker.length >= fence.length &&
          text.trim() === marker
        )
          fence = "";
      } else if (!fence) {
        const m = /^ {0,3}(#{1,6})[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$/.exec(text);
        if (m) items.push({ title: m[2], level: m[1].length, from: offset });
      }
      offset += text.length + 1;
    }
    this.headings = items;
    this.callbacks.outline(items);
  }
  apply(patches: Patch[]) {
    this.view.dispatch({ changes: patches, userEvent: "input" });
    this.view.focus();
  }
  wrap(marker: string) {
    const { from, to } = this.view.state.selection.main,
      doc = this.view.state.doc;
    const n = marker.length;
    if (
      from >= n &&
      doc.sliceString(from - n, from) === marker &&
      doc.sliceString(to, to + n) === marker
    ) {
      this.view.dispatch({
        changes: [
          { from: from - n, to: from, insert: "" },
          { from: to, to: to + n, insert: "" },
        ],
        selection: { anchor: from - n, head: to - n },
        userEvent: "input",
      });
    } else
      this.view.dispatch({
        changes: [
          { from, insert: marker },
          { from: to, insert: marker },
        ],
        selection: { anchor: from + n, head: to + n },
        userEvent: "input",
      });
    this.view.focus();
    return true;
  }
  prefix(prefix: string) {
    const s = this.view.state.selection.main,
      doc = this.view.state.doc;
    const changes = [];
    for (
      let n = doc.lineAt(s.from).number;
      n <= doc.lineAt(s.to > s.from ? s.to - 1 : s.to).number;
      n++
    ) {
      const l = doc.line(n),
        m = /^(?:#{1,6}\s+|>\s?|[-*+]\s+|\d+[.)]\s+)/.exec(l.text);
      changes.push({
        from: l.from,
        to: l.from + (m?.[0].length ?? 0),
        insert: prefix,
      });
    }
    this.apply(changes);
    return true;
  }
  toggle() {
    this.sourceMode = !this.sourceMode;
    const top = this.view.scrollDOM.scrollTop;
    this.view.dispatch({
      effects: mode.reconfigure(this.sourceMode ? [] : preview),
    });
    this.view.dom.classList.toggle("is-source", this.sourceMode);
    this.view.scrollDOM.scrollTop = top;
    this.view.focus();
  }
  jump(from: number) {
    this.view.dispatch({
      selection: { anchor: from },
      effects: EditorView.scrollIntoView(from, { y: "start", yMargin: 40 }),
    });
    this.view.focus();
  }
  find() {
    openSearchPanel(this.view);
  }
  undo() {
    undo(this.view);
    this.view.focus();
  }
  redo() {
    redo(this.view);
    this.view.focus();
  }
  destroy() {
    clearTimeout(this.outlineTimer);
    this.view.destroy();
  }
}
