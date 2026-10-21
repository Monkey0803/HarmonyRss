/*
 * ShareIntent.test.ets — 分享 Want 解析地址的单测。
 */

import { describe, it, expect } from '@ohos/hypium';
import { Want } from '@kit.AbilityKit';
import { shareIntent } from '../../../main/ets/service/ShareIntent';

export default function shareIntentTest() {
  describe('ShareIntent', () => {
    it('extract_from_uri', 0, () => {
      const want: Want = { uri: 'https://a.com/feed' };
      const urls: string[] = shareIntent.extractSharedUrls(want);
      expect(urls.length).assertEqual(1);
      expect(urls[0]).assertEqual('https://a.com/feed');
    });

    it('extract_from_parameters', 0, () => {
      const want: Want = { parameters: { 'content': 'check https://b.com/rss and https://c.com/atom' } };
      const urls: string[] = shareIntent.extractSharedUrls(want);
      expect(urls.length).assertEqual(2);
      expect(urls[0]).assertEqual('https://b.com/rss');
      expect(urls[1]).assertEqual('https://c.com/atom');
    });

    it('extract_none', 0, () => {
      const want: Want = { parameters: { 'text': 'no url here' } };
      expect(shareIntent.extractSharedUrls(want).length).assertEqual(0);
    });

    it('extract_dedup', 0, () => {
      const want: Want = { uri: 'https://a.com/feed', parameters: { 'url': 'https://a.com/feed' } };
      expect(shareIntent.extractSharedUrls(want).length).assertEqual(1);
    });
  });
}
