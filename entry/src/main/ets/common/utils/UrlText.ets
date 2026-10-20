/*
 * UrlText.ets — 地址与文本的纯函数工具（无副作用，便于单测）。
 *
 * 供「添加订阅源」多处复用：单条输入归一化、从剪贴板 / 分享内容里提取地址、批量输入按行切分、
 * 判断两个地址是否同一站点（疑似重复）。
 */

import { url } from '@kit.ArkTS';

/**
 * 匹配 http(s) 地址：遇到空白或引号 / 括号 / 尖括号即止；同时排除中日韩表意文字与全角标点，
 * 避免把紧跟地址的中文（如「…/rss。还有」）一并吞掉（URL 里的中文应已被百分号编码）。
 */
const URL_PATTERN: RegExp = /https?:\/\/[^\s"'<>()\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]+/gi;
/** 会被从地址两端剥掉的包裹标点（中英文都要）。 */
const WRAP_CHARS: string = '"\'<>()[]，。、；;,.';
/** 批量输入的分隔符：换行 / 逗号 / 分号 / 空白。 */
const SPLIT_PATTERN: RegExp = /[\s,;，；]+/;

/** 两个地址是否同一站点（比较规范化后的主机名）。 */
function hostOf(value: string): string {
  const trimmed: string = value.trim();
  if (trimmed.length === 0) {
    return '';
  }
  try {
    return new url.URL(trimmed).hostname.toLowerCase();
  } catch (err) {
    return '';
  }
}

export class UrlText {
  /**
   * 归一化用户输入的单个地址：
   *   1) 去首尾空白；
   *   2) 剥掉两端可能被一起复制进来的标点 / 引号；
   *   3) 缺 scheme 且形如主机名时补 https://。
   * 不合法（空、无主机名特征）时返回空串。
   */
  static normalizeUrlInput(text: string): string {
    let value: string = UrlText.stripWrapping(text);
    if (value.length === 0) {
      return '';
    }
    if (!UrlText.hasScheme(value)) {
      if (!UrlText.looksLikeHost(value)) {
        return '';
      }
      value = 'https://' + value;
    }
    return value;
  }

  /** 从任意文本里提取 http(s) 地址：去重、保持出现顺序、逐项归一化。 */
  static extractUrls(text: string): string[] {
    const found: string[] = [];
    if (text.length === 0) {
      return found;
    }
    const seen: Set<string> = new Set();
    const matches: RegExpMatchArray | null = text.match(URL_PATTERN);
    if (matches === null) {
      return found;
    }
    for (let i = 0; i < matches.length; i += 1) {
      const normalized: string = UrlText.normalizeUrlInput(matches[i]);
      if (normalized.length > 0 && !seen.has(normalized)) {
        seen.add(normalized);
        found.push(normalized);
      }
    }
    return found;
  }

  /**
   * 批量输入切分：按换行 / 逗号 / 分号 / 空白拆开，逐项归一化，丢弃空项并去重。
   * 恰好 1 项时调用方走「预览」流程，多项走「批量」流程。
   */
  static splitUrlLines(text: string): string[] {
    const result: string[] = [];
    if (text.length === 0) {
      return result;
    }
    const seen: Set<string> = new Set();
    const parts: string[] = text.split(SPLIT_PATTERN);
    for (let i = 0; i < parts.length; i += 1) {
      const normalized: string = UrlText.normalizeUrlInput(parts[i]);
      if (normalized.length > 0 && !seen.has(normalized)) {
        seen.add(normalized);
        result.push(normalized);
      }
    }
    return result;
  }

  /** 两个地址是否同一站点；任一解析不出主机名时返回 false。 */
  static isSameSite(a: string, b: string): boolean {
    const hostA: string = hostOf(a);
    const hostB: string = hostOf(b);
    if (hostA.length === 0 || hostB.length === 0) {
      return false;
    }
    return hostA === hostB;
  }

  /** 剥掉两端的包裹标点并去首尾空白。 */
  private static stripWrapping(text: string): string {
    let value: string = text.trim();
    let start: number = 0;
    let end: number = value.length;
    while (start < end && WRAP_CHARS.indexOf(value.charAt(start)) >= 0) {
      start += 1;
    }
    while (end > start && WRAP_CHARS.indexOf(value.charAt(end - 1)) >= 0) {
      end -= 1;
    }
    value = value.substring(start, end).trim();
    return value;
  }

  /** 是否已带 http(s) scheme。 */
  private static hasScheme(value: string): boolean {
    const lower: string = value.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  /** 是否形如主机名（含点、点不在开头、无空格）——用来决定要不要补 https://。 */
  private static looksLikeHost(value: string): boolean {
    const slash: number = value.indexOf('/');
    const host: string = slash >= 0 ? value.substring(0, slash) : value;
    if (host.length === 0 || host.indexOf('.') <= 0) {
      return false;
    }
    return host.indexOf(' ') < 0;
  }
}
