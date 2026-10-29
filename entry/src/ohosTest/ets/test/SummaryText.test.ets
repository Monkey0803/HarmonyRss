/*
 * SummaryText.test.ets — 列表摘要清洗单测（去 CTA 尾巴 / 标题判重 / 句读截断）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { summarizeForList } from '../../../main/ets/common/utils/SummaryText';

export default function summaryTextTest() {
  describe('SummaryText', () => {
    it('keeps_short_text', 0, () => {
      expect(summarizeForList('Summary here', 'Title', 160)).assertEqual('Summary here');
    });

    it('strips_cta_tail', 0, () => {
      expect(summarizeForList('正文内容很长一段。阅读全文', 'Title', 160))
        .assertEqual('正文内容很长一段。');
      expect(summarizeForList('Some body text. Read more', 'Title', 160))
        .assertEqual('Some body text.');
    });

    it('drops_title_duplicate', 0, () => {
      expect(summarizeForList('Hello World!', 'hello   world', 160)).assertEqual('');
    });

    it('cuts_at_sentence', 0, () => {
      const long: string = '第一句话讲了一些事情。' + '第二句话继续补充内容，'.repeat(20);
      const out: string = summarizeForList(long, 'Title', 40);
      expect(out.length <= 41).assertTrue();
      expect(out.endsWith('…')).assertTrue();
      expect(out.startsWith('第一句话讲了一些事情。')).assertTrue();
    });

    it('empty_and_cta_only', 0, () => {
      expect(summarizeForList('', 'Title', 160)).assertEqual('');
      expect(summarizeForList('阅读全文', 'Title', 160)).assertEqual('');
      expect(summarizeForList('   ', 'Title', 160)).assertEqual('');
    });

    it('collapses_whitespace_and_zero_width', 0, () => {
      expect(summarizeForList('  a\u200b b\n\n c  ', 'Title', 160)).assertEqual('a b c');
    });

    it('drops_link_dump', 0, () => {
      expect(summarizeForList(
        'Article URL: https://example.com/a Comments URL: https://news.ycombinator.com/item?id=1 Points: 21',
        'Title', 160)).assertEqual('');
      expect(summarizeForList('https://example.com/a https://example.com/b', 'Title', 160)).assertEqual('');
    });
  });
}
