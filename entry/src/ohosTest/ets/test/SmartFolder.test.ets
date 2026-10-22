/*
 * SmartFolder.test.ets — 智能文件夹校验与排序纯函数单测。
 *
 * 覆盖：空查询拒绝、超长拒绝、名称校验、数量上限、上移 / 下移边界。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  movedIndex,
  normalizeFolderName,
  SmartFolderError,
  validateSmartFolder
} from '../../../main/ets/service/SmartFolderStore';
import { TagConstants } from '../../../main/ets/common/constants/RssConstants';

export default function smartFolderTest() {
  describe('SmartFolder', () => {
    it('accepts_valid_folder', 0, () => {
      expect(validateSmartFolder('未读', 'is:unread', 0, true)).assertEqual(SmartFolderError.NONE);
      expect(validateSmartFolder('AI', 'from:少数派 is:unread AI', 7, true))
        .assertEqual(SmartFolderError.NONE);
      // 引号短语也算有效查询。
      expect(validateSmartFolder('短语', '"harmony os"', 0, true)).assertEqual(SmartFolderError.NONE);
    });

    it('rejects_empty_query', 0, () => {
      expect(validateSmartFolder('未读', '', 0, true)).assertEqual(SmartFolderError.QUERY_EMPTY);
      expect(validateSmartFolder('未读', '   \t ', 0, true)).assertEqual(SmartFolderError.QUERY_EMPTY);
      // 只有无效语法（from: 后面没有值）也视为空查询。
      expect(validateSmartFolder('未读', 'from:', 0, true)).assertEqual(SmartFolderError.QUERY_EMPTY);
    });

    it('rejects_too_long_query', 0, () => {
      const long: string = 'a'.repeat(TagConstants.SMART_FOLDER_QUERY_MAX + 1);
      expect(validateSmartFolder('长', long, 0, true)).assertEqual(SmartFolderError.QUERY_TOO_LONG);
      // 恰好等于上限可以通过。
      const exact: string = 'b'.repeat(TagConstants.SMART_FOLDER_QUERY_MAX);
      expect(validateSmartFolder('长', exact, 0, true)).assertEqual(SmartFolderError.NONE);
    });

    it('rejects_bad_name', 0, () => {
      expect(validateSmartFolder('', 'is:unread', 0, true)).assertEqual(SmartFolderError.NAME_EMPTY);
      expect(validateSmartFolder('   ', 'is:unread', 0, true)).assertEqual(SmartFolderError.NAME_EMPTY);
      const longName: string = 'n'.repeat(TagConstants.TAG_NAME_MAX + 1);
      expect(validateSmartFolder(longName, 'is:unread', 0, true)).assertEqual(SmartFolderError.NAME_TOO_LONG);
    });

    it('rejects_over_limit_only_on_create', 0, () => {
      expect(validateSmartFolder('新', 'is:unread', TagConstants.MAX_SMART_FOLDERS, true))
        .assertEqual(SmartFolderError.LIMIT_REACHED);
      // 编辑已有条目不受数量上限影响。
      expect(validateSmartFolder('旧', 'is:unread', TagConstants.MAX_SMART_FOLDERS, false))
        .assertEqual(SmartFolderError.NONE);
      expect(validateSmartFolder('新', 'is:unread', TagConstants.MAX_SMART_FOLDERS - 1, true))
        .assertEqual(SmartFolderError.NONE);
    });

    it('normalize_folder_name', 0, () => {
      expect(normalizeFolderName('  未读   收藏  ')).assertEqual('未读 收藏');
      expect(normalizeFolderName('AI')).assertEqual('AI');
    });

    it('move_index_swaps_and_clamps', 0, () => {
      // 正常上移 / 下移。
      expect(movedIndex(1, -1, 3)).assertEqual(0);
      expect(movedIndex(1, 1, 3)).assertEqual(2);
      // 边界不越界（保持原下标）。
      expect(movedIndex(0, -1, 3)).assertEqual(0);
      expect(movedIndex(2, 1, 3)).assertEqual(2);
      // 只有一项时不动。
      expect(movedIndex(0, 1, 1)).assertEqual(0);
      // 越界下标原样返回。
      expect(movedIndex(-1, 1, 3)).assertEqual(-1);
      expect(movedIndex(5, -1, 3)).assertEqual(5);
    });
  });
}
