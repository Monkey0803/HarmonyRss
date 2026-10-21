/*
 * OpmlCodec.test.ets — OPML 2.0 编解码单测（分组解析 / 往返一致 / 去重）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { parseOpml, buildOpml, OpmlEntry } from '../../../main/ets/service/OpmlCodec';
import { FeedSource } from '../../../main/ets/model/Feed';

const GROUPED_OPML: string =
  '<?xml version="1.0" encoding="UTF-8"?><opml version="2.0"><body>' +
  '<outline text="Tech">' +
  '<outline type="rss" text="A" xmlUrl="https://a.com/feed" htmlUrl="https://a.com"/>' +
  '</outline>' +
  '<outline type="rss" text="B" xmlUrl="https://b.com/feed"/>' +
  '</body></opml>';

export default function opmlCodecTest() {
  describe('OpmlCodec', () => {
    it('parse_groups', 0, () => {
      const entries: OpmlEntry[] = parseOpml(GROUPED_OPML);
      expect(entries.length).assertEqual(2);
      expect(entries[0].xmlUrl).assertEqual('https://a.com/feed');
      expect(entries[0].title).assertEqual('A');
      expect(entries[0].group).assertEqual('Tech');
      expect(entries[1].xmlUrl).assertEqual('https://b.com/feed');
      expect(entries[1].group).assertEqual('');
    });

    it('parse_dedup', 0, () => {
      const xml: string =
        '<opml><body>' +
        '<outline type="rss" text="A" xmlUrl="https://a.com/feed"/>' +
        '<outline type="rss" text="A again" xmlUrl="https://a.com/feed"/>' +
        '</body></opml>';
      expect(parseOpml(xml).length).assertEqual(1);
    });

    it('build_and_roundtrip', 0, () => {
      const feeds: FeedSource[] = [
        new FeedSource('https://a.com/feed', 'A', 'https://a.com/feed', 'https://a.com', 'Tech'),
        new FeedSource('https://b.com/feed', 'B', 'https://b.com/feed', 'https://b.com', '')
      ];
      const entries: OpmlEntry[] = parseOpml(buildOpml(feeds));
      expect(entries.length).assertEqual(2);
      expect(entries[0].xmlUrl).assertEqual('https://a.com/feed');
      expect(entries[0].group).assertEqual('Tech');
      expect(entries[1].xmlUrl).assertEqual('https://b.com/feed');
      expect(entries[1].group).assertEqual('');
    });
  });
}
