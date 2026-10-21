/*
 * FeedDiscovery.test.ets — feed autodiscovery 单测（<link> 扫描 / 相对地址 / <base href> / 兜底路径）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { feedDiscovery } from '../../../main/ets/service/FeedDiscovery';

export default function feedDiscoveryTest() {
  describe('FeedDiscovery', () => {
    it('discovers_alternate_link', 0, () => {
      const html: string =
        '<html><head><link rel="alternate" type="application/rss+xml" href="/feed.xml"></head></html>';
      const urls: string[] = feedDiscovery.candidateUrls(html, 'https://example.com/blog');
      expect(urls.length).assertEqual(1);
      expect(urls[0]).assertEqual('https://example.com/feed.xml');
    });

    it('resolves_relative_href', 0, () => {
      const html: string = '<link rel="alternate" type="application/atom+xml" href="../atom.xml">';
      const urls: string[] = feedDiscovery.candidateUrls(html, 'https://example.com/posts/');
      expect(urls[0]).assertEqual('https://example.com/atom.xml');
    });

    it('respects_base_href', 0, () => {
      const html: string =
        '<head><base href="https://cdn.example.com/root/"></head>' +
        '<link rel="alternate" type="application/rss+xml" href="feed.xml">';
      const urls: string[] = feedDiscovery.candidateUrls(html, 'https://example.com/page');
      expect(urls[0]).assertEqual('https://cdn.example.com/root/feed.xml');
    });

    it('fallback_when_no_link', 0, () => {
      const urls: string[] = feedDiscovery.candidateUrls('<html><body>hi</body></html>', 'https://example.com/');
      expect(urls.indexOf('https://example.com/feed') >= 0).assertTrue();
      expect(urls.indexOf('https://example.com/rss.xml') >= 0).assertTrue();
    });

    it('no_fallback_when_link_found', 0, () => {
      const html: string = '<link rel="alternate" type="application/rss+xml" href="/feed.xml">';
      const urls: string[] = feedDiscovery.candidateUrls(html, 'https://example.com/');
      expect(urls.length).assertEqual(1);
    });

    it('dedup_identical_links', 0, () => {
      const html: string =
        '<link rel="alternate" type="application/rss+xml" href="/feed.xml">' +
        '<link rel="alternate" type="application/rss+xml" href="/feed.xml">';
      const urls: string[] = feedDiscovery.candidateUrls(html, 'https://example.com/');
      expect(urls.length).assertEqual(1);
    });

    it('ignores_non_feed_link', 0, () => {
      const html: string = '<link rel="alternate" type="text/html" href="/page.html">';
      const urls: string[] = feedDiscovery.candidateUrls(html, 'https://example.com/');
      expect(urls.indexOf('https://example.com/page.html') < 0).assertTrue();
    });

    it('json_feed_type', 0, () => {
      const html: string = '<link rel="alternate" type="application/feed+json" href="/feed.json">';
      const urls: string[] = feedDiscovery.candidateUrls(html, 'https://example.com/');
      expect(urls[0]).assertEqual('https://example.com/feed.json');
    });
  });
}
