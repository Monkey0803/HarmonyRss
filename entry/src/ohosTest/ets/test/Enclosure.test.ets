/*
 * Enclosure.test.ets — 媒体附件解析 / 编解码 / 类型与时长纯逻辑单测。
 *
 * 覆盖：
 *   - RSS <enclosure> + <itunes:duration>（纯秒 / mm:ss / hh:mm:ss）；
 *   - Atom <link rel="enclosure">；
 *   - Media RSS <media:content type|medium duration>；
 *   - JSON Feed attachments；
 *   - 编解码往返、脏数据、类型兜底（URL 后缀）与时长格式化。
 */

import { describe, it, expect } from '@ohos/hypium';
import { Enclosure, MediaKind, formatDuration, mediaKindOf } from '../../../main/ets/model/Enclosure';
import { decodeEnclosures, durationFromText, encodeEnclosures } from '../../../main/ets/service/EnclosureCodec';
import { parseFeed } from '../../../main/ets/service/RssParser';
import { parseJsonFeed } from '../../../main/ets/service/JsonFeedParser';

const RSS: string =
  '<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">' +
  '<channel><title>Podcast</title><link>https://example.com</link><item>' +
  '<title>Episode 1</title><link>https://example.com/1</link>' +
  '<enclosure url="https://cdn.example.com/1.mp3" length="123456" type="audio/mpeg"/>' +
  '<itunes:duration>35:12</itunes:duration>' +
  '</item></channel></rss>';

const ATOM: string =
  '<feed xmlns="http://www.w3.org/2005/Atom"><title>Vlog</title><link rel="alternate" href="https://example.com"/>' +
  '<entry><title>Video 1</title><link rel="alternate" href="https://example.com/v1"/>' +
  '<link rel="enclosure" href="https://cdn.example.com/v1.mp4" type="video/mp4" length="999"/>' +
  '</entry></feed>';

const MEDIA_RSS: string =
  '<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel><title>Media</title>' +
  '<link>https://example.com</link><item><title>Audio</title><link>https://example.com/a</link>' +
  '<media:content url="https://cdn.example.com/a.m4a" type="audio/mp4" duration="123"/>' +
  '</item></channel></rss>';

const JSON_FEED: string =
  '{"title":"Json","home_page_url":"https://example.com","items":[{"id":"1","title":"Ep",' +
  '"url":"https://example.com/j1","attachments":[{"url":"https://cdn.example.com/j1.m4a",' +
  '"mime_type":"audio/mp4","size_in_bytes":42,"duration_in_seconds":300}]}]}';

export default function enclosureTest() {
  describe('Enclosure', () => {
    it('rss_enclosure_and_itunes_duration', 0, () => {
      const feed = parseFeed(RSS);
      expect(feed.articles.length).assertEqual(1);
      const list: Enclosure[] = feed.articles[0].enclosures;
      expect(list.length).assertEqual(1);
      expect(list[0].url).assertEqual('https://cdn.example.com/1.mp3');
      expect(list[0].type).assertEqual('audio/mpeg');
      expect(list[0].length).assertEqual(123456);
      expect(list[0].duration).assertEqual(35 * 60 + 12);
      expect(list[0].isAudio()).assertTrue();
    });

    it('atom_link_enclosure', 0, () => {
      const feed = parseFeed(ATOM);
      const list: Enclosure[] = feed.articles[0].enclosures;
      expect(list.length).assertEqual(1);
      expect(list[0].url).assertEqual('https://cdn.example.com/v1.mp4');
      expect(list[0].isVideo()).assertTrue();
      expect(list[0].length).assertEqual(999);
    });

    it('media_rss_content', 0, () => {
      const feed = parseFeed(MEDIA_RSS);
      const list: Enclosure[] = feed.articles[0].enclosures;
      expect(list.length).assertEqual(1);
      expect(list[0].url).assertEqual('https://cdn.example.com/a.m4a');
      expect(list[0].duration).assertEqual(123);
      expect(list[0].isAudio()).assertTrue();
    });

    it('json_feed_attachments', 0, () => {
      const feed = parseJsonFeed(JSON_FEED);
      const list: Enclosure[] = feed.articles[0].enclosures;
      expect(list.length).assertEqual(1);
      expect(list[0].url).assertEqual('https://cdn.example.com/j1.m4a');
      expect(list[0].type).assertEqual('audio/mp4');
      expect(list[0].length).assertEqual(42);
      expect(list[0].duration).assertEqual(300);
    });

    it('codec_round_trip_and_bad_json', 0, () => {
      const source: Enclosure[] = [
        new Enclosure('https://x/1.mp3', 'audio/mpeg', 100, 200),
        new Enclosure('https://x/2.mp4', 'video/mp4', 300, 400)
      ];
      const decoded: Enclosure[] = decodeEnclosures(encodeEnclosures(source));
      expect(decoded.length).assertEqual(2);
      expect(decoded[0].url).assertEqual('https://x/1.mp3');
      expect(decoded[0].duration).assertEqual(200);
      expect(decoded[1].isVideo()).assertTrue();
      expect(decodeEnclosures('not-json').length).assertEqual(0);
      expect(decodeEnclosures('{}').length).assertEqual(0);
    });

    it('duration_text_variants', 0, () => {
      expect(durationFromText('123')).assertEqual(123);
      expect(durationFromText('02:03')).assertEqual(123);
      expect(durationFromText('1:02:03')).assertEqual(3723);
      expect(durationFromText('')).assertEqual(0);
      expect(durationFromText('abc')).assertEqual(0);
      expect(durationFromText('1::2')).assertEqual(0);
    });

    it('media_kind_by_mime_or_extension', 0, () => {
      expect(mediaKindOf('audio/mpeg', 'https://x/a')).assertEqual(MediaKind.AUDIO);
      expect(mediaKindOf('', 'https://x/a.MP3?token=1')).assertEqual(MediaKind.AUDIO);
      expect(mediaKindOf('', 'https://x/a.mp4')).assertEqual(MediaKind.VIDEO);
      expect(mediaKindOf('image/jpeg', 'https://x/a.jpg')).assertEqual(MediaKind.IMAGE);
      expect(mediaKindOf('', 'https://x/a.html')).assertEqual(MediaKind.OTHER);
    });

    it('format_duration', 0, () => {
      expect(formatDuration(0)).assertEqual('0:00');
      expect(formatDuration(65)).assertEqual('1:05');
      expect(formatDuration(3723)).assertEqual('1:02:03');
      expect(formatDuration(-5)).assertEqual('0:00');
    });
  });
}
