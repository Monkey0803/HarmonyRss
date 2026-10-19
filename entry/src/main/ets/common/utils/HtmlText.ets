/*
 * HtmlText.ets — HTML 片段 → 纯文本（供「复制正文 / 分享正文 / 朗读 / 搜索索引」复用）。
 *
 * 阅读器正文是受控的净化后 HTML（标签集很窄，见 HtmlSanitizer），所以这里只需要
 * 一个轻量的去标签 + 实体解码：把块级标签换成换行、行内标签直接丢掉，
 * 再折叠空白，最后按上限截断。
 */

/** 块级标签：标签处补一个换行，保证段落不粘成一行。 */
const BLOCK_TAGS: string[] = [
  'p', 'div', 'br', 'hr', 'li', 'ul', 'ol', 'dl', 'dt', 'dd', 'blockquote', 'pre',
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'figure', 'figcaption', 'table', 'tr', 'td', 'th', 'section', 'article'
];

/** 纯文本上限（字符）：避免整库/整篇超长文本进内存或 EI。 */
export const PLAIN_TEXT_MAX_CHARS: number = 30000;

function isBlockTag(tag: string): boolean {
  return BLOCK_TAGS.indexOf(tag) >= 0;
}

/** 常见命名实体（净化后的正文里基本只有这几个）。 */
function decodeEntities(text: string): string {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, '\'')
    .replace(/&apos;/g, '\'')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&');
}

/**
 * 去标签取纯文本：
 *   - 去掉 script/style/head 之类整段内容（理论上净化时已删，这里兜底）；
 *   - 块级标签 → 换行，行内标签 → 直接丢；
 *   - 解码实体、折叠空白、裁掉首尾空行、按上限截断。
 */
export function toPlainText(html: string): string {
  if (html.length === 0) {
    return '';
  }
  // 先摘掉整段不需要的内容
  let text: string = html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<head[\s\S]*?<\/head>/gi, ' ')
    .replace(/<!--[\s\S]*?-->/g, ' ');

  // 块级标签换成换行，行内标签直接去掉
  text = text.replace(/<(\/?)([a-zA-Z][a-zA-Z0-9]*)\b[^>]*>/g, (match: string, slashPos: string, name: string) => {
    const tag: string = name.toLowerCase();
    if (!isBlockTag(tag)) {
      return '';
    }
    return slashPos === '/' ? '\n' : '\n';
  });

  text = decodeEntities(text);
  // 折叠行内空白，再把连续空行压成一个
  text = text.replace(/[ \t\r\f\v\u00a0]+/g, ' ').replace(/\n{2,}/g, '\n');
  // 每行去掉首尾空格
  const lines: string[] = text.split('\n');
  const cleaned: string[] = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line: string = lines[i].trim();
    if (line.length > 0) {
      cleaned.push(line);
    }
  }
  text = cleaned.join('\n').trim();
  if (text.length > PLAIN_TEXT_MAX_CHARS) {
    text = text.substring(0, PLAIN_TEXT_MAX_CHARS);
  }
  return text;
}
