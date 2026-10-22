/*
 * CjkTokenizer.test.ets — 中文检索分词纯函数单测（CJK 判定 / 片段切分 / grams / 查询 token / 复核判定）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  CjkRun,
  grams,
  hasCjkText,
  isCjkCode,
  needsPostFilter,
  queryTokens,
  splitRuns
} from '../../../main/ets/service/CjkTokenizer';

export default function cjkTokenizerTest() {
  describe('CjkTokenizer', () => {
    it('is_cjk_code', 0, () => {
      expect(isCjkCode('鸿'.charCodeAt(0))).assertTrue();
      expect(isCjkCode('あ'.charCodeAt(0))).assertTrue();
      expect(isCjkCode('ア'.charCodeAt(0))).assertTrue();
      expect(isCjkCode('한'.charCodeAt(0))).assertTrue();
      expect(isCjkCode('a'.charCodeAt(0))).assertFalse();
      expect(isCjkCode('1'.charCodeAt(0))).assertFalse();
      expect(isCjkCode('，'.charCodeAt(0))).assertFalse();
    });

    it('has_cjk_text', 0, () => {
      expect(hasCjkText('鸿蒙')).assertTrue();
      expect(hasCjkText('harmony 鸿蒙')).assertTrue();
      expect(hasCjkText('harmony rss')).assertFalse();
      expect(hasCjkText('')).assertFalse();
      expect(hasCjkText('123 %_*')).assertFalse();
    });

    it('split_runs', 0, () => {
      const runs: CjkRun[] = splitRuns('鸿蒙 RSS 开发');
      expect(runs.length).assertEqual(3);
      expect(runs[0].cjk).assertTrue();
      expect(runs[0].text).assertEqual('鸿蒙');
      expect(runs[1].cjk).assertFalse();
      expect(runs[1].text).assertEqual(' RSS ');
      expect(runs[2].cjk).assertTrue();
      expect(runs[2].text).assertEqual('开发');
      // 空串不产生片段。
      expect(splitRuns('').length).assertEqual(0);
    });

    it('grams_single_and_bigram', 0, () => {
      // 单字 + 相邻二元组；两个字 → 鸿 / 鸿蒙 / 蒙。
      expect(grams('鸿蒙', 20000)).assertEqual('鸿 鸿蒙 蒙');
      // 单字文档只有单字 token（保证单字查询可命中）。
      expect(grams('鸿', 20000)).assertEqual('鸿');
      // 非 CJK 文本不产 token（英文走主索引）。
      expect(grams('harmony rss', 20000)).assertEqual('');
      expect(grams('', 20000)).assertEqual('');
    });

    it('grams_skips_punctuation_boundary', 0, () => {
      // 标点是边界：不会生成跨标点的二元组。
      expect(grams('鸿蒙，开发', 20000)).assertEqual('鸿 鸿蒙 蒙 开 开发 发');
      // 中英混排只保留 CJK 片段。
      expect(grams('RSS 鸿蒙', 20000)).assertEqual('鸿 鸿蒙 蒙');
    });

    it('grams_dedupes_tokens', 0, () => {
      // 同一文档内 token 去重以控制体积。
      expect(grams('鸿蒙鸿蒙', 20000)).assertEqual('鸿 鸿蒙 蒙 蒙鸿');
    });

    it('grams_respects_max_chars', 0, () => {
      const limited: string = grams('鸿蒙开发', 5);
      expect(limited).assertEqual('鸿 鸿蒙');
      expect(limited.length <= 5).assertTrue();
      // 上限为 0 / 负数时不产 token。
      expect(grams('鸿蒙', 0)).assertEqual('');
      expect(grams('鸿蒙', -1)).assertEqual('');
    });

    it('query_tokens', 0, () => {
      expect(queryTokens('鸿').join(',')).assertEqual('鸿');
      expect(queryTokens('鸿蒙').join(',')).assertEqual('鸿蒙');
      expect(queryTokens('鸿蒙开发').join(',')).assertEqual('鸿蒙,蒙开,开发');
      // 非 CJK 片段不产 token。
      expect(queryTokens('harmony').length).assertEqual(0);
      expect(queryTokens('RSS 鸿蒙').join(',')).assertEqual('鸿蒙');
      // 重复二元组去重。
      expect(queryTokens('鸿蒙鸿蒙').join(',')).assertEqual('鸿蒙,蒙鸿');
    });

    it('needs_post_filter', 0, () => {
      // 单字 / 双字是精确 token，无需复核。
      expect(needsPostFilter('鸿')).assertFalse();
      expect(needsPostFilter('鸿蒙')).assertFalse();
      // ≥3 字必须子串复核，消除二元组不连续的误召回。
      expect(needsPostFilter('鸿蒙开发')).assertTrue();
      // 中英混排需要英文片段复核。
      expect(needsPostFilter('鸿蒙OS')).assertTrue();
      // 纯英文不经过中文索引。
      expect(needsPostFilter('harmony')).assertFalse();
      // 标点不触发复核（跨标点查询按 token AND 近似召回）。
      expect(needsPostFilter('鸿蒙，开发')).assertFalse();
    });
  });
}
