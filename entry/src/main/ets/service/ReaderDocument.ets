/*
 * ReaderDocument.ets — 把净化后的正文片段包成一份受控的完整 HTML 文档。
 *
 * 文档内联阅读 CSS：字号 / 行距 / 字体族 / 栏宽 / 对齐 / 阅读主题全部由 App 掌控，
 * 不再依赖站点样式。阅读主题：
 *   system —— 配色跟随系统深浅色（body 透明，融入应用沉浸背景）；
 *   light / sepia / dark —— 使用不透明阅读底色（这就是「阅读主题」的意义）。
 */

import { appSettings } from '../model/AppSettings';
import { ReaderTypography, ReaderTheme } from '../common/constants/SettingsConstants';

/** 一套阅读配色。bg 为空串表示透明（跟随应用背景）。 */
class ReaderPalette {
  readonly system: boolean;
  readonly bg: string;
  readonly fg: string;
  readonly link: string;
  readonly quoteFg: string;
  readonly quoteBorder: string;
  readonly codeBg: string;
  readonly border: string;
  readonly captionFg: string;

  constructor(system: boolean, bg: string, fg: string, link: string, quoteFg: string,
    quoteBorder: string, codeBg: string, border: string, captionFg: string) {
    this.system = system;
    this.bg = bg;
    this.fg = fg;
    this.link = link;
    this.quoteFg = quoteFg;
    this.quoteBorder = quoteBorder;
    this.codeBg = codeBg;
    this.border = border;
    this.captionFg = captionFg;
  }
}

const SYSTEM: ReaderPalette = new ReaderPalette(true, '', '#1f1f1f', '#0a66c2', '#555', '#cfcfcf',
  '#f0f0f0', '#ddd', '#777');
const LIGHT: ReaderPalette = new ReaderPalette(false, '#ffffff', '#1f1f1f', '#0a66c2', '#555', '#cfcfcf',
  '#f0f0f0', '#ddd', '#777');
const SEPIA: ReaderPalette = new ReaderPalette(false, '#f6ecd9', '#3b3226', '#8a5a1a', '#6b5b45', '#d8c8a8',
  '#efe3cc', '#ddcdb0', '#8a7a5f');
const DARK: ReaderPalette = new ReaderPalette(false, '#1b1b1b', '#e6e6e6', '#6cb6ff', '#aaaaaa', '#4a4a4a',
  '#2a2a2a', '#444444', '#9a9a9a');

function paletteOf(id: string): ReaderPalette {
  if (id === ReaderTheme.LIGHT) {
    return LIGHT;
  }
  if (id === ReaderTheme.SEPIA) {
    return SEPIA;
  }
  if (id === ReaderTheme.DARK) {
    return DARK;
  }
  return SYSTEM;
}

/** 正文字号（px）。 */
function fontSize(): number {
  return ReaderTypography.fontSizePx(appSettings.readerFontScale);
}

/** 行高（px）。 */
function lineHeight(): number {
  return fontSize() * ReaderTypography.lineHeightOf(appSettings.readerLineScale);
}

/** body 规则（底色 / 字色 / 字体 / 字号行距）。 */
function bodyRule(p: ReaderPalette): string {
  const family: string = ReaderTypography.fontFamilyCss(appSettings.readerFontFamily);
  let rule: string = 'body{background:' + (p.bg.length > 0 ? p.bg : 'transparent') + ';color:' + p.fg +
    ';font-size:' + fontSize() + 'px;line-height:' + lineHeight() + 'px;' +
    'word-wrap:break-word;-webkit-text-size-adjust:100%;-webkit-font-smoothing:antialiased;';
  if (family.length > 0) {
    rule += 'font-family:' + family + ';';
  }
  return rule + '}';
}

/** 主题相关元素规则（链接 / 引用 / 代码 / 表格 / 图注）。topPad / bottomPad 为浮层让位的内边距（CSS px）。 */
function elementRules(p: ReaderPalette, topPad: number, bottomPad: number): string {
  const align: string = ReaderTypography.textAlignCss(appSettings.readerAlign);
  const width: number = ReaderTypography.contentWidthPx(appSettings.readerWidth);
  return '.reader{max-width:' + width + 'px;margin:0 auto;padding:' + (16 + topPad) + 'px 20px ' +
    (56 + bottomPad) + 'px;}' +
    '.reader p,.reader li,.reader blockquote{text-align:' + align + ';}' +
    '.reader a{color:' + p.link + ';text-decoration:none;word-break:break-word;}' +
    '.reader code{background:' + p.codeBg + ';padding:.1em .35em;border-radius:4px;font-family:monospace;font-size:.92em;}' +
    '.reader pre{background:' + p.codeBg + ';padding:12px;border-radius:8px;overflow-x:auto;font-size:.9em;}' +
    '.reader pre code{background:none;padding:0;}' +
    '.reader blockquote{margin:1em 0;padding:.2em 1em;border-left:3px solid ' + p.quoteBorder + ';color:' + p.quoteFg + ';}' +
    '.reader td,.reader th{border:1px solid ' + p.border + ';padding:6px 8px;text-align:left;}' +
    '.reader hr{border:none;border-top:1px solid ' + p.border + ';margin:1.6em 0;}' +
    '.reader figcaption{font-size:.85em;color:' + p.captionFg + ';text-align:center;margin-top:6px;}';
}

/** 与主题无关的固定排版（图片 / 列表 / 标题 / 表格）。 */
function structuralRules(): string {
  // 显式允许选择与复制：阅读器里选段后要能用系统菜单/自定义操作条复制、分享。
  return 'html,body{margin:0;padding:0;-webkit-user-select:text;user-select:text;}' +
    '.reader img{max-width:100%;height:auto;display:block;margin:12px auto;border-radius:8px;}' +
    // 内嵌媒体：视频 / 音频 / 播放器撑满栏宽，播放器按 16:9 占位避免布局跳动
    '.reader video,.reader audio{width:100%;max-width:100%;display:block;margin:12px auto;border-radius:8px;}' +
    '.reader iframe{width:100%;aspect-ratio:16/9;border:0;border-radius:8px;margin:12px auto;display:block;}' +
    '.reader video,.reader iframe{max-width:100%;}' +
    '.reader p{margin:0 0 1em;}' +
    '.reader h1,.reader h2,.reader h3,.reader h4{line-height:1.35;margin:1.4em 0 .6em;font-weight:600;}' +
    '.reader h1{font-size:1.5em;}.reader h2{font-size:1.3em;}.reader h3{font-size:1.15em;}' +
    '.reader ul,.reader ol{margin:0 0 1em;padding-left:1.4em;}' +
    '.reader li{margin:.3em 0;}' +
    '.reader figure{margin:1em 0;}' +
    '.reader table{width:100%;border-collapse:collapse;margin:1em 0;font-size:.95em;}';
}

/** 系统主题下的深色覆盖（显式浅色配色在深色系统里的替换）。 */
function darkOverride(): string {
  return '@media (prefers-color-scheme: dark){' +
    'body{color:' + DARK.fg + ';}' +
    '.reader a{color:' + DARK.link + ';}' +
    '.reader code,.reader pre{background:' + DARK.codeBg + ';}' +
    '.reader blockquote{color:' + DARK.quoteFg + ';border-left-color:' + DARK.quoteBorder + ';}' +
    '.reader td,.reader th{border-color:' + DARK.border + ';}' +
    '.reader hr{border-top-color:' + DARK.border + ';}' +
    '.reader figcaption{color:' + DARK.captionFg + ';}' +
    '}';
}

/**
 * 阅读 CSS（正文排版 + 主题）。
 *
 * topPad / bottomPad：为浮在正文之上的标题栏 / 悬浮底栏让出的内边距（CSS px）。
 * 沉浸式布局下正文铺满整页、从两栏下方穿过，正文首尾必须自己留出这段空间才不会被挡住。
 */
export function readerCss(topPad: number = 0, bottomPad: number = 0): string {
  const palette: ReaderPalette = paletteOf(appSettings.readerTheme);
  const scheme: string = palette.system ? ':root{color-scheme:light dark;}' : ':root{color-scheme:' +
    (appSettings.readerTheme === ReaderTheme.DARK ? 'dark' : 'light') + ';}';
  let css: string = scheme + bodyRule(palette) + structuralRules() + elementRules(palette, topPad, bottomPad);
  if (palette.system) {
    css += darkOverride();
  }
  return css;
}

/** 拼一份完整 HTML 文档（片段已净化，可直接内嵌）。 */
export function buildReaderDocument(bodyHtml: string, topPad: number = 0, bottomPad: number = 0): string {
  return '<!DOCTYPE html><html><head>' +
    '<meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">' +
    '<style>' + readerCss(topPad, bottomPad) + '</style>' +
    '</head><body><article class="reader">' + bodyHtml + '</article></body></html>';
}
