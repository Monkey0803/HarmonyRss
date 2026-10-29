/*
 * SummaryText.ets — 列表摘要清洗（纯函数，便于单测）。
 *
 * feed 的 description / summary 常常不是「一段正文」，而是：
 *   - 正文截断 + 「阅读全文」这类尾巴；
 *   - 与标题几乎相同的复读；
 *   - 在词/句中间硬截断。
 * 列表里既要短又要能读，所以在解析阶段做一次清洗：
 *   1. 折叠空白、去零宽字符；
 *   2. 剥掉结尾的行动号召（CTA）与省略号尾巴；
 *   3. 与标题去重（相同则返回空串，列表自然不显示摘要行）；
 *   4. 超长时优先在句读处截断，而不是硬切。
 */

/** 结尾的行动号召 / 省略号尾巴（可连续出现多次，大小写不敏感）。 */
const CTA_TAIL: RegExp = new RegExp(
  '(?:\\s*(?:阅读全文|阅读原文|继续阅读|点击阅读|查看全文|Read\\s*more|Continue\\s*reading|…|\\.\\.\\.)' +
  '\\s*[»>›→]*[。.!！?？]?)+\\s*$', 'i');

/** 比较「是否与标题重复」时忽略的字符：空白与常见中英标点。 */
const TITLE_NOISE: RegExp =
  /[\s\u3000.,:;!?'"`~@#$%^&*()<>\\/|+=\-_，。！？；：、“”‘’（）《》【】…—]/g;

/** 折叠空白并去掉零宽字符。 */
function flatten(raw: string): string {
  return raw.replace(/[\u200b\ufeff]/g, '').replace(/\s+/g, ' ').trim();
}

/** 去重比较用的归一化形态。 */
function comparable(text: string): string {
  return text.replace(TITLE_NOISE, '').toLowerCase();
}

/** 在句读处截断（找不到就找空格，再不行才硬截）。 */
function cutAtSentence(text: string, max: number): string {
  const min: number = Math.floor(max * 0.6);
  const marks: string = '。！？；.!?;';
  for (let i = max - 1; i >= min; i -= 1) {
    if (marks.indexOf(text.charAt(i)) >= 0) {
      return text.substring(0, i + 1);
    }
  }
  for (let i = max - 1; i >= min; i -= 1) {
    if (text.charAt(i) === ' ') {
      return text.substring(0, i);
    }
  }
  return text.substring(0, max);
}

/**
 * 清洗列表摘要。
 * @param raw   已去标签的摘要原文（parser 负责 stripTags / 实体解码）
 * @param title 文章标题（用于判重）
 * @param max   字符上限
 * @returns 可展示的摘要；空串表示「不该显示摘要行」
 */
export function summarizeForList(raw: string, title: string, max: number): string {
  let text: string = flatten(raw).replace(CTA_TAIL, '').trim();
  // 剥掉 CTA 后可能留下孤立的分隔符（句子本身的句号 / 问号要保留）。
  text = text.replace(/[\s,，;；:：]+$/, '').trim();
  if (text.length === 0) {
    return '';
  }
  if (comparable(text) === comparable(flatten(title))) {
    return '';
  }
  if (text.length <= max) {
    return text;
  }
  const cut: string = cutAtSentence(text, max).trim();
  if (cut.length === 0) {
    return '';
  }
  return cut + '…';
}
