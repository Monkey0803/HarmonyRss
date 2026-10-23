/*
 * DedupeKeys.ets — 跨源去重的归一化键（纯函数，无副作用，便于单测）。
 *
 * 两个键：
 *   1) urlKey：同一条链接在不同站点上可能带大小写 host、锚点、跟踪参数、末尾斜杠，
 *      归一后比较才不会漏合并；同时保留 path 大小写与 query 顺序，避免把不同页面误判成同一篇。
 *   2) titleKey：转载标题常有空格 / 全角半角标点 / 大小写差异，去掉这些噪声后再比较。
 *
 * 所有函数对空输入返回空串（空键表示「不参与该维度匹配」），不抛异常。
 */

import { url } from '@kit.ArkTS';
import { RssConstants } from '../common/constants/RssConstants';

/** 精确匹配的跟踪参数（小写比较）；utm_* 前缀单独判断。 */
const TRACKING_PARAMS: string[] = ['fbclid', 'gclid', 'ref', 'source'];

/**
 * 标题归一化时要剔除的字符：空白 + 中英文标点 / 符号。
 * 统一用 Unicode 转义写中文引号等容易与字符串定界符混淆的字符，避免编辑期被“智能引号”改坏；
 * 用字符集合（而非正则字符类）也避开了 '-'、']'、'\' 在 ArkTS 正则里的转义差异。
 */
const TITLE_DROP_CHARS: string = ' \t\r\n\u00a0\u3000' +
  '\uff0c\u3002\uff01\uff1f\u3001\uff1b\uff1a\u201c\u201d\u2018\u2019\uff08\uff09' +
  '\u3010\u3011\u300a\u300b\u3008\u3009\u300c\u300d\u300e\u300f\u3014\u3015' +
  '\u2026\u2014\uff5e\u00b7' +
  ',.!?;:"\'`()[]{}<>-_~|/\\@#$%^&*+=';

/** 其它空白（如全角空格之外的 Unicode 空白）兜底判断。 */
const WHITESPACE_PATTERN: RegExp = /\s/;

/** 标题归一化最多处理的字符数（超长标题只看前 N 个字符，避免异常数据拖慢入库）。 */
const TITLE_KEY_MAX_CHARS: number = 512;

/** 跨源去重的归一化键。 */
export class DedupeKeys {
  /**
   * URL 归一化键：
   *   1) 小写 scheme / host（保留 path 与 query 的大小写）；
   *   2) 去 fragment（# 之后）；
   *   3) 去掉 utm_*、fbclid、gclid、ref、source 查询参数，其余参数的相对顺序保持不变；
   *   4) 去掉 path 末尾多余的 '/'（根路径也归一为空）。
   * 解析失败（相对地址、非法串）时返回「去空白 + 小写」的原串，至少保证同串同键。
   */
  static urlKey(rawUrl: string): string {
    const trimmed: string = rawUrl.trim();
    if (trimmed.length === 0) {
      return '';
    }
    const parsed: url.URL | undefined = DedupeKeys.parse(trimmed);
    if (parsed === undefined) {
      return trimmed.toLowerCase();
    }
    const protocol: string = parsed.protocol.toLowerCase();
    const host: string = parsed.host.toLowerCase();
    // 只对 http(s) 做结构化归一；mailto: 之类没有「站点」概念，退回原串比较。
    if ((protocol !== 'http:' && protocol !== 'https:') || host.length === 0) {
      return trimmed.toLowerCase();
    }
    let pathname: string = parsed.pathname;
    while (pathname.length > 1 && pathname.endsWith('/')) {
      pathname = pathname.substring(0, pathname.length - 1);
    }
    if (pathname === '/') {
      pathname = '';
    }
    return protocol + '//' + host + pathname + DedupeKeys.filterQuery(parsed.search);
  }

  /**
   * 标题归一化键：小写 → 去掉空白与中英文标点 → 去首尾。
   * 标题为空（或归一后为空）时返回空串，调用方据此跳过标题维度匹配。
   */
  static titleKey(rawTitle: string): string {
    const lower: string = rawTitle.toLowerCase();
    const limit: number = Math.min(lower.length, TITLE_KEY_MAX_CHARS);
    let out: string = '';
    for (let i = 0; i < limit; i += 1) {
      const ch: string = lower.charAt(i);
      if (TITLE_DROP_CHARS.indexOf(ch) >= 0) {
        continue;
      }
      if (WHITESPACE_PATTERN.test(ch)) {
        continue;
      }
      out += ch;
    }
    return out.trim();
  }

  /**
   * 标题判定的时间窗：任一时间为 0（缺失）时用 fallback（入库时间）代替，
   * 两个时间相差不超过 24 小时才算同一篇。
   */
  static sameTitleWindow(a: number, b: number, fallback: number = Date.now()): boolean {
    const left: number = a > 0 ? a : fallback;
    const right: number = b > 0 ? b : fallback;
    return Math.abs(left - right) <= RssConstants.DEDUPE_WINDOW_MS;
  }

  /** 解析 URL；非法串返回 undefined（不抛异常）。 */
  private static parse(raw: string): url.URL | undefined {
    try {
      return url.URL.parseURL(raw);
    } catch (err) {
      return undefined;
    }
  }

  /** 过滤跟踪参数：保留其余参数的原始顺序；全部被过滤掉时返回空串（不含 '?'）。 */
  private static filterQuery(search: string): string {
    if (search.length === 0) {
      return '';
    }
    const raw: string = search.startsWith('?') ? search.substring(1) : search;
    if (raw.length === 0) {
      return '';
    }
    const parts: string[] = raw.split('&');
    const kept: string[] = [];
    for (let i = 0; i < parts.length; i += 1) {
      const part: string = parts[i];
      if (part.length === 0) {
        continue;
      }
      const eq: number = part.indexOf('=');
      const key: string = (eq >= 0 ? part.substring(0, eq) : part).toLowerCase();
      if (key.startsWith('utm_') || TRACKING_PARAMS.indexOf(key) >= 0) {
        continue;
      }
      kept.push(part);
    }
    return kept.length === 0 ? '' : '?' + kept.join('&');
  }
}

/** 函数式入口（单测 / 调用点可直接 import）。 */
export function urlKey(rawUrl: string): string {
  return DedupeKeys.urlKey(rawUrl);
}

/** 函数式入口：标题归一化键。 */
export function titleKey(rawTitle: string): string {
  return DedupeKeys.titleKey(rawTitle);
}

/** 函数式入口：标题判定的 ±24h 时间窗。 */
export function sameTitleWindow(a: number, b: number, fallback: number = Date.now()): boolean {
  return DedupeKeys.sameTitleWindow(a, b, fallback);
}
