/*
 * UrlText.test.ets — 地址/文本纯函数单测（归一化 / 提取 / 批量分行 / 同站判断）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { UrlText } from '../../../main/ets/common/utils/UrlText';

export default function urlTextTest() {
  describe('UrlText', () => {
    it('normalize_adds_scheme', 0, () => {
      expect(UrlText.normalizeUrlInput('example.com/feed')).assertEqual('https://example.com/feed');
      expect(UrlText.normalizeUrlInput('  blog.example.org/rss  ')).assertEqual('https://blog.example.org/rss');
    });

    it('normalize_keeps_scheme', 0, () => {
      expect(UrlText.normalizeUrlInput('https://a.com/feed')).assertEqual('https://a.com/feed');
      expect(UrlText.normalizeUrlInput('HTTP://a.com/feed')).assertEqual('HTTP://a.com/feed');
    });

    it('normalize_strips_wrapping', 0, () => {
      expect(UrlText.normalizeUrlInput('<https://a.com/rss>')).assertEqual('https://a.com/rss');
      expect(UrlText.normalizeUrlInput('(https://a.com/rss)')).assertEqual('https://a.com/rss');
      expect(UrlText.normalizeUrlInput('https://a.com/rss.')).assertEqual('https://a.com/rss');
      expect(UrlText.normalizeUrlInput('https://a.com/rss，')).assertEqual('https://a.com/rss');
    });

    it('normalize_rejects_non_url', 0, () => {
      expect(UrlText.normalizeUrlInput('')).assertEqual('');
      expect(UrlText.normalizeUrlInput('   ')).assertEqual('');
      expect(UrlText.normalizeUrlInput('not a url')).assertEqual('');
      expect(UrlText.normalizeUrlInput('just-text')).assertEqual('');
    });

    it('extract_urls_dedup_and_order', 0, () => {
      const text: string = '看这个 https://a.com/feed 和 http://b.com/rss。还有 https://a.com/feed';
      const urls: string[] = UrlText.extractUrls(text);
      expect(urls.length).assertEqual(2);
      expect(urls[0]).assertEqual('https://a.com/feed');
      expect(urls[1]).assertEqual('http://b.com/rss');
    });

    it('extract_urls_empty', 0, () => {
      expect(UrlText.extractUrls('没有链接').length).assertEqual(0);
    });

    it('split_url_lines', 0, () => {
      const text: string = 'a.com/feed\nhttps://b.com/rss, c.com/atom；d.com/rss';
      const urls: string[] = UrlText.splitUrlLines(text);
      expect(urls.length).assertEqual(4);
      expect(urls[0]).assertEqual('https://a.com/feed');
      expect(urls[1]).assertEqual('https://b.com/rss');
      expect(urls[2]).assertEqual('https://c.com/atom');
      expect(urls[3]).assertEqual('https://d.com/rss');
    });

    it('split_url_lines_dedup', 0, () => {
      const urls: string[] = UrlText.splitUrlLines('https://a.com/feed\nhttps://a.com/feed');
      expect(urls.length).assertEqual(1);
    });

    it('is_same_site', 0, () => {
      expect(UrlText.isSameSite('https://a.com/feed', 'http://a.com/other')).assertTrue();
      expect(UrlText.isSameSite('https://a.com', 'https://b.com')).assertFalse();
      expect(UrlText.isSameSite('', 'https://a.com')).assertFalse();
    });

    it('origin_keeps_scheme_host_and_port', 0, () => {
      expect(UrlText.origin('https://fixture.invalid/path?q=1')).assertEqual('https://fixture.invalid');
      expect(UrlText.origin('http://fixture.invalid:8080/feed')).assertEqual('http://fixture.invalid:8080');
      expect(UrlText.origin('ftp://fixture.invalid/icon.png')).assertEqual('');
      expect(UrlText.origin('not a url')).assertEqual('');
    });

    it('resolve_makes_relative_icon_absolute', 0, () => {
      expect(UrlText.resolve('https://fixture.invalid/feed.xml', '/icon.png'))
        .assertEqual('https://fixture.invalid/icon.png');
      expect(UrlText.resolve('https://fixture.invalid/feed.xml', 'icon.png'))
        .assertEqual('https://fixture.invalid/icon.png');
      expect(UrlText.resolve('https://fixture.invalid/feed.xml', 'https://other.invalid/i.png'))
        .assertEqual('https://other.invalid/i.png');
      expect(UrlText.resolve('', '/icon.png')).assertEqual('');
      expect(UrlText.resolve('https://fixture.invalid/feed.xml', '')).assertEqual('');
    });
  });
}
