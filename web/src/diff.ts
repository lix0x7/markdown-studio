import {
  parseTree,
  format,
  applyEdits,
  type Node,
  type ParseError,
} from "jsonc-parser";
import { Text } from "@codemirror/state";
import { Chunk } from "@codemirror/merge";
export type DiffBlock = {
  from: number;
  to: number;
  left: string;
  right: string;
  original: string;
};

// 用专用代码围栏保存 JSON，任意代码文本（包括 HTML 和围栏）都能无损往返。
export function diffMarkup(left: string, right: string): string {
  return "```md-diff\n" + JSON.stringify({ left, right }) + "\n```";
}
export function parseDiffs(text: string): DiffBlock[] {
  const blocks: DiffBlock[] = [];
  let fence = "",
    start = 0,
    content = 0,
    offset = 0,
    isDiff = false;
  for (const line of text.split("\n")) {
    const marker = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (marker && !fence) {
      fence = marker[1];
      start = offset;
      content = offset + line.length + 1;
      isDiff = marker[2].trim() === "md-diff";
    } else if (
      marker &&
      fence &&
      marker[1][0] === fence[0] &&
      marker[1].length >= fence.length &&
      !marker[2].trim()
    ) {
      if (isDiff) {
        try {
          const value = JSON.parse(text.slice(content, offset));
          if (
            value &&
            typeof value.left === "string" &&
            typeof value.right === "string"
          )
            blocks.push({
              from: start,
              to: offset + line.length,
              left: value.left,
              right: value.right,
              original: text.slice(start, offset + line.length),
            });
        } catch {
          /* 无效数据保留为普通代码块，避免丢失用户内容。 */
        }
      }
      fence = "";
    }
    offset += line.length + 1;
  }
  return blocks;
}
export function formatDiffJSON(text: string, sort: boolean): string {
  const errors: ParseError[] = [];
  const tree = parseTree(text, errors, {
    disallowComments: true,
    allowTrailingComma: false,
  });
  if (!tree || errors.length) throw new Error("不是有效的 JSON，原文已保留");
  // 数字直接使用原始 token，避免大整数经过 JavaScript Number 后损失精度。
  const ordered = (node: Node): string => {
    if (node.type === "array")
      return "[" + (node.children ?? []).map(ordered).join(",") + "]";
    if (node.type === "object")
      return (
        "{" +
        [...(node.children ?? [])]
          .sort((a, b) =>
            a.children![0].value < b.children![0].value
              ? -1
              : a.children![0].value > b.children![0].value
                ? 1
                : 0,
          )
          .map((property) => {
            const [key, value] = property.children!;
            return (
              text.slice(key.offset, key.offset + key.length) +
              ":" +
              ordered(value)
            );
          })
          .join(",") +
        "}"
      );
    return text.slice(node.offset, node.offset + node.length);
  };
  const source = sort ? ordered(tree) : text;
  return applyEdits(
    source,
    format(source, undefined, { insertSpaces: true, tabSize: 2, eol: "\n" }),
  ).trim();
}

// 导出保留双栏与字符差异，所有代码文本先转义，避免作为 HTML 执行。
export function renderDiffHTML(block: DiffBlock): string {
  const chunks = Chunk.build(
    Text.of(block.left.split("\n")),
    Text.of(block.right.split("\n")),
  );
  return (
    '<div style="display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:12px">' +
    (["left", "right"] as const)
      .map((side, index) => {
        const text = block[side];
        const escape = (value: string) =>
          value.replace(
            /[&<>"']/g,
            (c) =>
              ({
                "&": "&amp;",
                "<": "&lt;",
                ">": "&gt;",
                '"': "&quot;",
                "'": "&#39;",
              })[c]!,
          );
        let at = 0,
          html = "";
        for (const chunk of chunks)
          for (const change of chunk.changes) {
            const from =
              index === 0
                ? chunk.fromA + change.fromA
                : chunk.fromB + change.fromB;
            const to =
              index === 0 ? chunk.fromA + change.toA : chunk.fromB + change.toB;
            html +=
              escape(text.slice(at, from)) +
              '<mark style="background:' +
              (index === 0 ? "#f7c4bf" : "#bfe7cb") +
              '">' +
              escape(text.slice(from, to)) +
              "</mark>";
            at = to;
          }
        return (
          '<section style="min-width:0"><strong>' +
          (index === 0 ? "左侧" : "右侧") +
          '</strong><pre style="overflow:auto;white-space:pre-wrap">' +
          html +
          escape(text.slice(at)) +
          "</pre></section>"
        );
      })
      .join("") +
    "</div>"
  );
}
