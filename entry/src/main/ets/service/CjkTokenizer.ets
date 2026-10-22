/*
 * CjkTokenizer.ets — 中文检索的纯函数（无副作用、可单测）。
 *
 * 背景：设备的 ICU 分词能力不可控（建表时就可能失败），所以中文检索不依赖分词器，
 * 而是在写入时把正文预切成「CJK 单字 + 相邻二元组」的 token 流，检索时把查询词切成同样的 token。
 *
 * 约定：
 *   - 只有 CJK 片段（汉字 / 假名 / 谚文）产 token，拉丁字母与标点不产（英文走主 FTS 索引）；
 *   - 单字 token 保证单字查询不漏召回，二元组 token 保证多字查询能走索引；
 *   - 同一文档内 token 去重，总字符数受上限约束（由调用方传入）。
 */

/** 一段同质文本：cjk = true 表示整段都是 CJK 字符。 */
export class CjkRun {
  readonly text: string;
  readonly cjk: boolean;

  constructor(text: string, cjk: boolean) {
    this.text = text;
    this.cjk = cjk;
  }
}

/** 单字 + 二元组需要的最大片段长度（超过则必须做子串复核）。 */
const MIN_POST_FILTER_RUN: number = 3;

/** 是否为 CJK 字符（按 UTF-16 码元判断；补充平面字符按非 CJK 处理）。 */
export function isCjkCode(code: number): boolean {
  // 假名（平假名 / 片假名）。
  if (code >= 0x3040 && code <= 0x30ff) {
    return true;
  }
  // 汉字扩展 A。
  if (code >= 0x3400 && code <= 0x4dbf) {
    return true;
  }
  // 汉字基本区。
  if (code >= 0x4e00 && code <= 0x9fff) {
    return true;
  }
  // 汉字兼容区。
  if (code >= 0xf900 && code <= 0xfaff) {
    return true;
  }
  // 谚文字母 / 谚文音节。
  if (code >= 0x1100 && code <= 0x11ff) {
    return true;
  }
  if (code >= 0xac00 && code <= 0xd7af) {
    return true;
  }
  return false;
}

/** 文本是否含 CJK 字符。 */
export function hasCjkText(text: string): boolean {
  for (let i = 0; i < text.length; i += 1) {
    if (isCjkCode(text.charCodeAt(i))) {
      return true;
    }
  }
  return false;
}

/** 把文本拆成「CJK 片段 / 非 CJK 片段」的序列（相邻同类字符合并）。 */
export function splitRuns(text: string): CjkRun[] {
  const runs: CjkRun[] = [];
  if (text.length === 0) {
    return runs;
  }
  let current: string = '';
  let currentCjk: boolean = isCjkCode(text.charCodeAt(0));
  for (let i = 0; i < text.length; i += 1) {
    const cjk: boolean = isCjkCode(text.charCodeAt(i));
    if (cjk !== currentCjk) {
      if (current.length > 0) {
        runs.push(new CjkRun(current, currentCjk));
      }
      current = '';
      currentCjk = cjk;
    }
    current += text.charAt(i);
  }
  if (current.length > 0) {
    runs.push(new CjkRun(current, currentCjk));
  }
  return runs;
}

/** 片段里是否含拉丁字母 / 数字（用于识别中英混排，标点不算）。 */
function hasWordChar(text: string): boolean {
  for (let i = 0; i < text.length; i += 1) {
    const code: number = text.charCodeAt(i);
    const digit: boolean = code >= 0x30 && code <= 0x39;
    const upper: boolean = code >= 0x41 && code <= 0x5a;
    const lower: boolean = code >= 0x61 && code <= 0x7a;
    if (digit || upper || lower) {
      return true;
    }
  }
  return false;
}

/**
 * 生成索引用 token 流（空格分隔）：CJK 片段内「每个字 + 每对相邻二字」，
 * 同一文档内去重；输出字符数（含分隔空格）超过 maxChars 时截断。
 */
export function grams(text: string, maxChars: number): string {
  if (text.length === 0 || maxChars <= 0) {
    return '';
  }
  const runs: CjkRun[] = splitRuns(text);
  const seen: Set<string> = new Set<string>();
  const parts: string[] = [];
  let total: number = 0;
  let truncated: boolean = false;
  for (let r = 0; r < runs.length && !truncated; r += 1) {
    const run: CjkRun = runs[r];
    if (!run.cjk) {
      continue;
    }
    const length: number = run.text.length;
    for (let i = 0; i < length && !truncated; i += 1) {
      // 单字 token：保证单字查询可命中。
      const singles: string[] = [run.text.substring(i, i + 1)];
      // 相邻二元组：保证双字 / 多字查询能走索引。
      if (i + 1 < length) {
        singles.push(run.text.substring(i, i + 2));
      }
      for (let t = 0; t < singles.length; t += 1) {
        const token: string = singles[t];
        if (seen.has(token)) {
          continue;
        }
        const extra: number = parts.length === 0 ? token.length : token.length + 1;
        if (total + extra > maxChars) {
          truncated = true;
          break;
        }
        seen.add(token);
        parts.push(token);
        total += extra;
      }
    }
  }
  return parts.join(' ');
}

/**
 * 把查询词转换成 MATCH 用的 token：
 * 单字片段 → 单字 token；双字片段 → 二元组；≥3 字片段 → 所有相邻二元组（AND 关系由调用方拼）。
 */
export function queryTokens(term: string): string[] {
  const runs: CjkRun[] = splitRuns(term);
  const seen: Set<string> = new Set<string>();
  const tokens: string[] = [];
  for (let r = 0; r < runs.length; r += 1) {
    const run: CjkRun = runs[r];
    if (!run.cjk) {
      continue;
    }
    const length: number = run.text.length;
    if (length === 1) {
      if (!seen.has(run.text)) {
        seen.add(run.text);
        tokens.push(run.text);
      }
      continue;
    }
    for (let i = 0; i + 1 < length; i += 1) {
      const token: string = run.text.substring(i, i + 2);
      if (!seen.has(token)) {
        seen.add(token);
        tokens.push(token);
      }
    }
  }
  return tokens;
}

/**
 * 该查询词是否需要「候选集复核」：
 *   - 含长度 ≥3 的中文片段（二元组 AND 会放过不连续的字符组合，必须用子串复核消除误召回）；
 *   - 中英混排（英文片段不在中文索引里，必须用大小写不敏感的子串 / LIKE 复核）。
 * 单字、双字纯中文片段是精确 token，无需复核。
 */
export function needsPostFilter(term: string): boolean {
  const runs: CjkRun[] = splitRuns(term);
  let cjkChars: number = 0;
  let hasWord: boolean = false;
  for (let r = 0; r < runs.length; r += 1) {
    const run: CjkRun = runs[r];
    if (run.cjk) {
      cjkChars += run.text.length;
      if (run.text.length >= MIN_POST_FILTER_RUN) {
        return true;
      }
    } else if (hasWordChar(run.text)) {
      hasWord = true;
    }
  }
  return hasWord && cjkChars > 0;
}
