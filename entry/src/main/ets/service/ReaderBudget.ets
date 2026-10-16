/*
 * ReaderBudget.ets — Reader 正文体积预算（无依赖，便于单测）。
 *
 * 单篇 reader_html = 提取文本（≤ MAX_READER_HTML_CHARS）+ 内联图片（≤ MAX_INLINE_TOTAL_CHARS）。
 * 两者叠加后仍可能偏大，这里做最后一道总预算：超限则放弃内联图片（保留远程链接），
 * 保证写入本地库的单篇体积有界，避免个别图片极多的文章把库撑爆。
 */

export class ReaderBudget {
  /** 单篇 reader_html 总字符上限（含内联图片）。 */
  static readonly MAX_TOTAL_CHARS: number = 1600 * 1024;

  /**
   * 在「内联版」与「纯文本版」之间做选择：内联后未超预算就用内联版，否则退回纯文本版。
   * fresh 是未内联的提取结果，inlined 是内联图片后的结果。
   */
  static fit(fresh: string, inlined: string): string {
    return inlined.length <= ReaderBudget.MAX_TOTAL_CHARS ? inlined : fresh;
  }
}
