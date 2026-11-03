/*
 * FeedAvatar.test.ets — 首字母头像的初始字 / 颜色稳定性 / 白字对比度单测。
 */

import { describe, it, expect } from '@ohos/hypium';
import { feedAvatarColor, feedInitial } from '../../../main/ets/common/utils/FeedAvatar';
import { ThemeColorMath } from '../../../main/ets/common/utils/ThemeColorMath';

export default function feedAvatarTest() {
  describe('FeedAvatar', () => {
    it('initial_uses_first_letter', 0, () => {
      expect(feedInitial('sspai')).assertEqual('S');
      expect(feedInitial('  少数派')).assertEqual('少');
      expect(feedInitial('')).assertEqual('?');
    });

    it('color_is_stable_for_same_title', 0, () => {
      expect(feedAvatarColor('少数派')).assertEqual(feedAvatarColor('少数派'));
    });

    it('white_text_is_readable', 0, () => {
      const color: string = feedAvatarColor('Hacker News');
      expect(ThemeColorMath.contrast(color, '#FFFFFF') >= 4.5).assertTrue();
    });
  });
}
