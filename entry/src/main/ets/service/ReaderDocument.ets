/*
 * ReaderDocument.ets — 把净化后的正文片段包成一份受控的完整 HTML 文档。
 *
 * 文档内联阅读 CSS：字号 / 行距取自设置，栏宽 / 图片 / 代码块 / 引用等由 App 掌控，
 * 不再依赖站点样式；配色用 prefers-color-scheme 跟随系统深浅色（配合 Web 的 darkMode Auto）。
 */

import { appSettings } from '../model/AppSettings';
import { ReaderTypography } from '../common/constants/SettingsConstants';

/** 正文字号（px）。 */
function fontSize(): number {
  return ReaderTypography.fontSize(appSettings.readerFont);
}

/** 行高（px）。 */
function lineHeight(): number {
  return ReaderTypography.fontSize(appSettings.readerFont)
    * ReaderTypography.lineHeight(appSettings.readerLine);
}

/** 阅读 CSS（正文排版 + 深浅色）。 */
export function readerCss(): string {
  const size: number = fontSize();
  const line: number = lineHeight();
  return ':root{color-scheme:light dark;}' +
    'html,body{margin:0;padding:0;}' +
    'body{background:transparent;color:#1f1f1f;font-size:' + size + 'px;line-height:' + line + 'px;' +
    'word-wrap:break-word;-webkit-text-size-adjust:100%;-webkit-font-smoothing:antialiased;}' +
    '.reader{max-width:720px;margin:0 auto;padding:16px 20px 56px;}' +
    '.reader img{max-width:100%;height:auto;display:block;margin:12px auto;border-radius:8px;}' +
    '.reader video,.reader iframe{max-width:100%;}' +
    '.reader p{margin:0 0 1em;}' +
    '.reader h1,.reader h2,.reader h3,.reader h4{line-height:1.35;margin:1.4em 0 .6em;font-weight:600;}' +
    '.reader h1{font-size:1.5em;}.reader h2{font-size:1.3em;}.reader h3{font-size:1.15em;}' +
    '.reader ul,.reader ol{margin:0 0 1em;padding-left:1.4em;}' +
    '.reader li{margin:.3em 0;}' +
    '.reader pre{background:#f4f4f4;padding:12px;border-radius:8px;overflow-x:auto;font-size:.9em;}' +
    '.reader pre code{background:none;padding:0;}' +
    '.reader code{background:#f0f0f0;padding:.1em .35em;border-radius:4px;font-family:monospace;font-size:.92em;}' +
    '.reader blockquote{margin:1em 0;padding:.2em 1em;border-left:3px solid #cfcfcf;color:#555;}' +
    '.reader a{color:#0a66c2;text-decoration:none;word-break:break-word;}' +
    '.reader figure{margin:1em 0;}' +
    '.reader figcaption{font-size:.85em;color:#777;text-align:center;margin-top:6px;}' +
    '.reader table{width:100%;border-collapse:collapse;margin:1em 0;font-size:.95em;}' +
    '.reader td,.reader th{border:1px solid #ddd;padding:6px 8px;text-align:left;}' +
    '.reader hr{border:none;border-top:1px solid #ddd;margin:1.6em 0;}' +
    '@media (prefers-color-scheme: dark){' +
    'body{color:#e6e6e6;}' +
    '.reader a{color:#6cb6ff;}' +
    '.reader code,.reader pre{background:#2a2a2a;}' +
    '.reader blockquote{color:#aaa;border-left-color:#4a4a4a;}' +
    '.reader td,.reader th{border-color:#444;}' +
    '.reader hr{border-top-color:#444;}' +
    '}';
}

/** 拼一份完整 HTML 文档（片段已净化，可直接内嵌）。 */
export function buildReaderDocument(bodyHtml: string): string {
  return '<!DOCTYPE html><html><head>' +
    '<meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">' +
    '<style>' + readerCss() + '</style>' +
    '</head><body><article class="reader">' + bodyHtml + '</article></body></html>';
}
