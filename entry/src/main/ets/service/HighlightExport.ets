/*
 * HighlightExport.ets — 标注导出（Markdown / JSON）。
 *
 * 纯函数：输入聚合好的标注，输出字符串，方便单独测、也方便以后加别的格式（如 CSV）。
 * JSON 里的字段名是稳定的对外契约，改动需谨慎；Markdown 按「文章 → 标注」分组，便于贴进笔记。
 */

import { HighlightLibraryItem } from '../model/Highlight';

/** 转义 Markdown 里会破坏结构的字符（引文可能含 * _ ` [ ] 等）。 */
function escapeMd(text: string): string {
  return text
    .replace(/\\/g, '\\\\')
    .replace(/([*_`[\]])/g, '\\$1');
}

/** JSON 字符串转义（不引第三方库，避免依赖）。 */
function escapeJson(text: string): string {
  let out: string = '';
  for (let i = 0; i < text.length; i += 1) {
    const ch: string = text.charAt(i);
    if (ch === '"') {
      out += '\\"';
    } else if (ch === '\\') {
      out += '\\\\';
    } else if (ch === '\n') {
      out += '\\n';
    } else if (ch === '\r') {
      out += '\\r';
    } else if (ch === '\t') {
      out += '\\t';
    } else {
      out += ch;
    }
  }
  return out;
}

/**
 * 导出 Markdown：按文章分组，每组一个标题（带原文链接），组内是引用块 + 备注。
 * 无标注时返回一句说明，避免分享空内容。
 */
export function toMarkdown(items: HighlightLibraryItem[], emptyHint: string): string {
  if (items.length === 0) {
    return emptyHint;
  }
  const lines: string[] = [];
  const seen: string[] = [];
  for (let i = 0; i < items.length; i += 1) {
    const entry: HighlightLibraryItem = items[i];
    const key: string = entry.highlight.articleId;
    if (seen.indexOf(key) < 0) {
      seen.push(key);
      lines.push('');
      const title: string = entry.articleTitle.length > 0 ? entry.articleTitle : entry.highlight.articleId;
      lines.push('## ' + escapeMd(title));
      if (entry.articleLink.length > 0) {
        lines.push('');
        lines.push('<' + entry.articleLink + '>');
      }
      if (entry.feedTitle.length > 0) {
        lines.push('');
        lines.push('_来源：' + escapeMd(entry.feedTitle) + '_');
      }
      lines.push('');
    }
    const quoteLines: string[] = entry.highlight.quote.split('\n');
    for (let q = 0; q < quoteLines.length; q += 1) {
      lines.push('> ' + escapeMd(quoteLines[q]));
    }
    if (entry.highlight.note.length > 0) {
      lines.push('');
      lines.push('**备注：** ' + escapeMd(entry.highlight.note));
    }
    lines.push('');
  }
  // 去掉开头多余的空行
  while (lines.length > 0 && lines[0].length === 0) {
    lines.shift();
  }
  return lines.join('\n');
}

/** 导出 JSON 数组（字段名是对外契约）。 */
export function toJson(items: HighlightLibraryItem[]): string {
  const parts: string[] = [];
  for (let i = 0; i < items.length; i += 1) {
    const entry: HighlightLibraryItem = items[i];
    parts.push('  {' +
      '"id":"' + escapeJson(entry.highlight.id) + '",' +
      '"articleId":"' + escapeJson(entry.highlight.articleId) + '",' +
      '"articleTitle":"' + escapeJson(entry.articleTitle) + '",' +
      '"articleLink":"' + escapeJson(entry.articleLink) + '",' +
      '"feedTitle":"' + escapeJson(entry.feedTitle) + '",' +
      '"quote":"' + escapeJson(entry.highlight.quote) + '",' +
      '"note":"' + escapeJson(entry.highlight.note) + '",' +
      '"color":"' + escapeJson(entry.highlight.color) + '",' +
      '"createdAt":' + entry.highlight.createdAt.toString() +
      '}');
  }
  return '[\n' + parts.join(',\n') + '\n]';
}
