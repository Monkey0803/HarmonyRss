/*
 * ReaderBudget.test.ets — 单篇 Reader 正文体积预算单测。
 */

import { describe, it, expect } from '@ohos/hypium';
import { ReaderBudget } from '../../../main/ets/service/ReaderBudget';

function repeat(ch: string, times: number): string {
  let out: string = '';
  for (let i = 0; i < times; i += 1) {
    out += ch;
  }
  return out;
}

export default function readerBudgetTest() {
  describe('ReaderBudget', () => {
    it('keeps_inlined_when_within_budget', 0, () => {
      expect(ReaderBudget.fit('text', 'text+images')).assertEqual('text+images');
    });

    it('falls_back_to_text_when_over_budget', 0, () => {
      const huge: string = repeat('x', ReaderBudget.MAX_TOTAL_CHARS + 1);
      expect(ReaderBudget.fit('text', huge)).assertEqual('text');
    });

    it('boundary_is_inclusive', 0, () => {
      const exact: string = repeat('x', ReaderBudget.MAX_TOTAL_CHARS);
      expect(ReaderBudget.fit('text', exact).length).assertEqual(ReaderBudget.MAX_TOTAL_CHARS);
    });
  });
}
