/*
 * TagStore.test.ets — 标签纯函数单测（名称归一 / 大小写去重 / 上限 / 多标签 AND 片段）。
 *
 * 只测不依赖数据库的部分：Store 的读写需要在真机上打开本地库，属于 UI 验证范围。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  canCreateTag,
  isValidTagName,
  multiTagAndClause,
  normalizeTagName,
  tagNameKey
} from '../../../main/ets/service/TagStore';
import { TagConstants } from '../../../main/ets/common/constants/RssConstants';

export default function tagStoreTest() {
  describe('TagStore', () => {
    it('normalize_trims_and_collapses_spaces', 0, () => {
      expect(normalizeTagName('  AI  ')).assertEqual('AI');
      expect(normalizeTagName('AI   Research')).assertEqual('AI Research');
      expect(normalizeTagName('a\t\n b')).assertEqual('a b');
      expect(normalizeTagName('   ')).assertEqual('');
    });

    it('normalize_truncates_to_max', 0, () => {
      const long: string = 'x'.repeat(TagConstants.TAG_NAME_MAX + 10);
      expect(normalizeTagName(long).length).assertEqual(TagConstants.TAG_NAME_MAX);
      // 恰好等于上限不受影响。
      const exact: string = 'y'.repeat(TagConstants.TAG_NAME_MAX);
      expect(normalizeTagName(exact)).assertEqual(exact);
    });

    it('name_key_is_case_insensitive', 0, () => {
      // 大小写不同、空白不同 → 同一个去重键。
      expect(tagNameKey('  AI  ')).assertEqual('ai');
      expect(tagNameKey('Ai')).assertEqual(tagNameKey(' aI '));
      expect(tagNameKey('Design')).assertEqual('design');
      // 中文不受大小写影响，但仍做空白折叠。
      expect(tagNameKey(' 设计  模式 ')).assertEqual('设计 模式');
    });

    it('valid_name', 0, () => {
      expect(isValidTagName('AI')).assertTrue();
      expect(isValidTagName('   ')).assertFalse();
      expect(isValidTagName('')).assertFalse();
      expect(isValidTagName('z'.repeat(TagConstants.TAG_NAME_MAX))).assertTrue();
    });

    it('limit_guard', 0, () => {
      expect(canCreateTag(0)).assertTrue();
      expect(canCreateTag(TagConstants.MAX_TAGS - 1)).assertTrue();
      expect(canCreateTag(TagConstants.MAX_TAGS)).assertFalse();
      expect(canCreateTag(TagConstants.MAX_TAGS + 1)).assertFalse();
    });

    it('multi_tag_and_clause', 0, () => {
      // 多标签是 AND：占位符数量与 HAVING 的标签数一致。
      const two: string = multiTagAndClause(2);
      expect(two.indexOf('at.tag_id IN (?,?)') >= 0).assertTrue();
      expect(two.indexOf('HAVING COUNT(DISTINCT at.tag_id) = 2') >= 0).assertTrue();
      const one: string = multiTagAndClause(1);
      expect(one.indexOf('IN (?)') >= 0).assertTrue();
      expect(one.indexOf('= 1') >= 0).assertTrue();
      const three: string = multiTagAndClause(3);
      expect(three.indexOf('IN (?,?,?)') >= 0).assertTrue();
      expect(three.indexOf('= 3') >= 0).assertTrue();
    });
  });
}
