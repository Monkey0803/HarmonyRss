/*
 * SwipeActionPlan.test.ets — 左滑「更多」菜单条目规则单测（纯数据，不涉及 ArkUI 渲染）。
 *
 * 为什么要测：左滑从 7 个平铺动作收口成「4 个直达块（分享 / 稍后读 / 已读 / 更多）+ 更多菜单」后，
 * 直达块是否够宽靠渲染层，但「菜单里该出现哪些动作」全靠这里的规则。规则写错的表现是：
 * 「已缓存的文章还给下载项」「清除了才发现要点两次」「源内列表冒出只看该源」
 * 「分享在直达块和菜单里各出现一次」—— 都要靠设备手滑才看得出来，所以先把数据层钉住。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  OFFLINE_FULL,
  OFFLINE_NONE,
  OFFLINE_PARTIAL,
  OFFLINE_TEXT,
  SwipeOverflowId,
  offlineOverflowIds,
  swipeOverflowIds
} from '../../../main/ets/common/components/SwipeActionPlan';

/** 把枚举数组拼成可断言的字符串序列。 */
function join(ids: SwipeOverflowId[]): string {
  return ids.join(',');
}

export default function swipeActionPlanTest() {
  describe('SwipeActionPlan', () => {
    it('offline_none_only_download', 0, () => {
      expect(join(offlineOverflowIds(OFFLINE_NONE))).assertEqual('offline_download');
      // 未知态按未缓存处理：宁可给一个点了会重抓的「下载」，也不要空菜单。
      expect(join(offlineOverflowIds(''))).assertEqual('offline_download');
      expect(join(offlineOverflowIds('unknown'))).assertEqual('offline_download');
    });

    it('offline_text_and_partial_retry_then_clear', 0, () => {
      expect(join(offlineOverflowIds(OFFLINE_TEXT))).assertEqual('offline_retry,offline_clear');
      expect(join(offlineOverflowIds(OFFLINE_PARTIAL))).assertEqual('offline_retry,offline_clear');
    });

    it('offline_full_only_clear', 0, () => {
      expect(join(offlineOverflowIds(OFFLINE_FULL))).assertEqual('offline_clear');
    });

    it('home_menu_offline_then_scope', 0, () => {
      expect(join(swipeOverflowIds(OFFLINE_NONE, true))).assertEqual('offline_download,scope_feed');
      expect(join(swipeOverflowIds(OFFLINE_PARTIAL, true)))
        .assertEqual('offline_retry,offline_clear,scope_feed');
      expect(join(swipeOverflowIds(OFFLINE_FULL, true))).assertEqual('offline_clear,scope_feed');
    });

    it('feed_list_menu_without_scope', 0, () => {
      expect(join(swipeOverflowIds(OFFLINE_NONE, false))).assertEqual('offline_download');
      expect(join(swipeOverflowIds(OFFLINE_FULL, false))).assertEqual('offline_clear');
    });

    it('share_never_in_overflow_menu', 0, () => {
      // 分享已上提为左滑直达块：菜单里再出现一次就会变成「同一动作两个入口」。
      const states: string[] = [OFFLINE_NONE, OFFLINE_TEXT, OFFLINE_PARTIAL, OFFLINE_FULL, 'unknown'];
      for (let i = 0; i < states.length; i += 1) {
        const ids: SwipeOverflowId[] = swipeOverflowIds(states[i], true);
        for (let j = 0; j < ids.length; j += 1) {
          expect(ids[j] === SwipeOverflowId.DOWNLOAD || ids[j] === SwipeOverflowId.RETRY ||
            ids[j] === SwipeOverflowId.CLEAR_OFFLINE || ids[j] === SwipeOverflowId.SCOPE_FEED).assertTrue();
        }
      }
    });

    it('ids_are_unique_and_never_empty', 0, () => {
      const states: string[] = [OFFLINE_NONE, OFFLINE_TEXT, OFFLINE_PARTIAL, OFFLINE_FULL, 'unknown'];
      for (let i = 0; i < states.length; i += 1) {
        const ids: SwipeOverflowId[] = swipeOverflowIds(states[i], true);
        expect(ids.length > 0).assertTrue();
        // ForEach / 菜单项都靠 id 去重：重复键会让菜单项丢失或点击错位。
        const seen: Set<string> = new Set<string>();
        for (let j = 0; j < ids.length; j += 1) {
          seen.add(ids[j]);
        }
        expect(seen.size).assertEqual(ids.length);
      }
    });
  });
}
