/*
 * TranslationPolicy.ets — 翻译的纯逻辑（不碰网络 / 数据库，可单测）。
 *
 *   detectLanguage      轻量语言识别（中文 / 英文 / 日文 / 韩文 / 俄文 / 阿拉伯文）
 *   targetLanguageOf    目标语言跟随应用语言（跟随系统时按系统语言决定中/英）
 *   splitParagraphs     正文 → 段落（长段按句号再切，保证逐段对照）
 *   chunkParagraphs     段落 → 每次请求的批次（字符与条数双重上限）
 *   endpointOf          provider + 用户自定义端点 → 实际请求地址
 *
 * 语言识别只用于「决定是否需要翻译」与提示，不追求准确率；翻译接口本身也支持自动检测。
 */

import { AppLanguage } from '../common/constants/SettingsConstants';
import { TranslateDefaults, TranslateLimits, TranslateProvider } from '../common/constants/TranslateConstants';

/** 归一翻译服务 id（脏值退回默认）。 */
export function normalizeProvider(value: string): string {
  if (value === TranslateProvider.LIBRE) {
    return TranslateProvider.LIBRE;
  }
  return TranslateProvider.DEEPL;
}

/** 用户自定义端点只接受 http/https，其它一律退回默认端点。 */
export function endpointOf(provider: string, custom: string): string {
  const text: string = custom.trim();
  const lower: string = text.toLowerCase();
  if (text.length > 0 && (lower.startsWith('https://') || lower.startsWith('http://'))) {
    return text;
  }
  return provider === TranslateProvider.LIBRE
    ? TranslateDefaults.LIBRE_ENDPOINT : TranslateDefaults.DEEPL_ENDPOINT;
}

/** 字符是否日文假名。 */
function isKana(code: number): boolean {
  return (code >= 0x3040 && code <= 0x30ff);
}

/** 字符是否韩文。 */
function isHangul(code: number): boolean {
  return (code >= 0x1100 && code <= 0x11ff) || (code >= 0xac00 && code <= 0xd7af);
}

/** 字符是否 CJK 汉字。 */
function isHan(code: number): boolean {
  return (code >= 0x3400 && code <= 0x4dbf) || (code >= 0x4e00 && code <= 0x9fff);
}

/** 字符是否西里尔字母。 */
function isCyrillic(code: number): boolean {
  return code >= 0x0400 && code <= 0x04ff;
}

/** 字符是否阿拉伯文。 */
function isArabic(code: number): boolean {
  return code >= 0x0600 && code <= 0x06ff;
}

/** 字符是否拉丁字母（含扩展区）。 */
function isLatin(code: number): boolean {
  return (code >= 0x0041 && code <= 0x005a) || (code >= 0x0061 && code <= 0x007a) ||
    (code >= 0x00c0 && code <= 0x024f);
}

/**
 * 轻量语言识别，返回 ISO 639-1（'zh' / 'en' / 'ja' / 'ko' / 'ru' / 'ar'），无法判断返回 'und'。
 * 判定顺序：假名 → 韩文 → 汉字（与拉丁比多少）→ 西里尔 → 阿拉伯 → 拉丁 → 未知。
 */
export function detectLanguage(text: string): string {
  let kana: number = 0;
  let hangul: number = 0;
  let han: number = 0;
  let cyrillic: number = 0;
  let arabic: number = 0;
  let latin: number = 0;
  for (let i = 0; i < text.length; i += 1) {
    const code: number = text.charCodeAt(i);
    if (isKana(code)) {
      kana += 1;
    } else if (isHangul(code)) {
      hangul += 1;
    } else if (isHan(code)) {
      han += 1;
    } else if (isCyrillic(code)) {
      cyrillic += 1;
    } else if (isArabic(code)) {
      arabic += 1;
    } else if (isLatin(code)) {
      latin += 1;
    }
  }
  if (kana > 0) {
    return 'ja';
  }
  if (hangul > 0) {
    return 'ko';
  }
  if (han > latin) {
    return 'zh';
  }
  if (cyrillic > latin) {
    return 'ru';
  }
  if (arabic > latin) {
    return 'ar';
  }
  if (latin > 0) {
    // 拉丁字母无法仅凭字符区间区分英 / 法 / 德 / 西…：用英文高频词判断，
    // 不像英文时返回 und（让翻译服务自己检测，避免把法语误判成英语而跳过翻译）。
    const words: RegExpMatchArray | null = text.toLowerCase().match(
      /\b(?:the|and|is|are|of|to|in|that|for|this|with|as|it|on|be|by|from|at)\b/g);
    return words !== null && words.length >= 2 ? 'en' : 'und';
  }
  return 'und';
}

/** 系统语言标签 → 目标语言（取语言主标签，不认识的一律英语）。 */
function targetOfSystemLanguage(systemLanguage: string): string {
  const lower: string = systemLanguage.toLowerCase();
  const supported: string[] = ['zh', 'en', 'ja', 'de', 'fr', 'es'];
  for (let i = 0; i < supported.length; i += 1) {
    if (lower.indexOf(supported[i]) === 0) {
      return supported[i];
    }
  }
  return 'en';
}

/**
 * 目标语言：跟随应用语言。
 * 显式选了语言就用该语言；跟随系统时按系统语言决定，没有对应资源的语言退回英语。
 */
export function targetLanguageOf(appLanguage: string, systemLanguage: string): string {
  if (appLanguage === AppLanguage.SYSTEM) {
    return targetOfSystemLanguage(systemLanguage);
  }
  if (appLanguage === AppLanguage.ZH_TW) {
    return 'zh-hant';
  }
  return appLanguage;
}

/** 中文（含繁体）与目标语言是否同一语言：同语言不必翻译。 */
export function isSameLanguage(source: string, target: string): boolean {
  if (source.length === 0 || source === 'und') {
    return false;
  }
  const sourceBase: string = source === 'zh-hant' || source === 'zh-hans' ? 'zh' : source;
  const targetBase: string = target === 'zh-hant' || target === 'zh-hans' ? 'zh' : target;
  return sourceBase === targetBase;
}

/** 句末标点（中英文）。 */
function isSentenceEnd(code: number): boolean {
  return code === 0x3002 || code === 0xff01 || code === 0xff1f ||
    code === 0x002e || code === 0x0021 || code === 0x003f;
}

/** 超长行按句末标点切分；切完仍超长的块再硬切。 */
function splitLongLine(line: string): string[] {
  const result: string[] = [];
  let start: number = 0;
  for (let i = 0; i < line.length; i += 1) {
    const code: number = line.charCodeAt(i);
    const length: number = i - start + 1;
    if (isSentenceEnd(code) && length >= 40) {
      result.push(line.substring(start, i + 1).trim());
      start = i + 1;
    }
  }
  if (start < line.length) {
    result.push(line.substring(start).trim());
  }
  const limited: string[] = [];
  for (let i = 0; i < result.length; i += 1) {
    const piece: string = result[i];
    if (piece.length === 0) {
      continue;
    }
    if (piece.length <= TranslateLimits.PARAGRAPH_CHARS) {
      limited.push(piece);
      continue;
    }
    let offset: number = 0;
    while (offset < piece.length) {
      limited.push(piece.substring(offset, offset + TranslateLimits.PARAGRAPH_CHARS));
      offset += TranslateLimits.PARAGRAPH_CHARS;
    }
  }
  return limited;
}

/**
 * 正文纯文本 → 段落列表。
 * 以换行为界（toPlainText 已把块级标签换成换行），长段按句号再切；
 * 去掉空行，按 MAX_PARAGRAPHS / MAX_CHARS 截断。
 */
export function splitParagraphs(text: string): string[] {
  const normalized: string = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const lines: string[] = normalized.split('\n');
  const result: string[] = [];
  let chars: number = 0;
  for (let i = 0; i < lines.length && result.length < TranslateLimits.MAX_PARAGRAPHS; i += 1) {
    const line: string = lines[i].trim();
    if (line.length === 0) {
      continue;
    }
    if (chars >= TranslateLimits.MAX_CHARS) {
      break;
    }
    const pieces: string[] = splitLongLine(line);
    for (let j = 0; j < pieces.length && result.length < TranslateLimits.MAX_PARAGRAPHS; j += 1) {
      const piece: string = pieces[j];
      if (piece.length === 0) {
        continue;
      }
      const remaining: number = TranslateLimits.MAX_CHARS - chars;
      if (remaining <= 0) {
        break;
      }
      if (piece.length > remaining) {
        result.push(piece.substring(0, remaining));
        chars = TranslateLimits.MAX_CHARS;
        break;
      }
      result.push(piece);
      chars += piece.length;
    }
  }
  return result;
}

/** 段落 → 请求批次（每批最多 maxCount 段、maxChars 字符）。 */
export function chunkParagraphs(paragraphs: string[], maxCount: number = TranslateLimits.MAX_BATCH_PARAGRAPHS,
  maxChars: number = TranslateLimits.MAX_BATCH_CHARS): string[][] {
  const batches: string[][] = [];
  const countLimit: number = maxCount > 0 ? Math.floor(maxCount) : TranslateLimits.MAX_BATCH_PARAGRAPHS;
  const charLimit: number = maxChars > 0 ? Math.floor(maxChars) : TranslateLimits.MAX_BATCH_CHARS;
  let current: string[] = [];
  let chars: number = 0;
  for (let i = 0; i < paragraphs.length; i += 1) {
    const paragraph: string = paragraphs[i];
    if (paragraph.length === 0) {
      continue;
    }
    const tooMany: boolean = current.length >= countLimit;
    const tooLong: boolean = current.length > 0 && chars + paragraph.length > charLimit;
    if (tooMany || tooLong) {
      batches.push(current);
      current = [];
      chars = 0;
    }
    current.push(paragraph);
    chars += paragraph.length;
  }
  if (current.length > 0) {
    batches.push(current);
  }
  return batches;
}

/** DeepL 目标语言码（大写；'zh' → 'ZH'）。 */
export function deepLTarget(code: string): string {
  return code.toUpperCase();
}

/** DeepL 源语言码；无法识别返回空串（让服务自动检测）。 */
export function deepLSource(code: string): string {
  return code.length > 0 && code !== 'und' ? code.toUpperCase() : '';
}
