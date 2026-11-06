/*
 * FeedDiscovery.test.ets — feed autodiscovery 单测（<link> 扫描 / 相对地址 / <base href> / 兜底路径）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { feedDiscovery, isFeedDocument } from '../../../main/ets/service/FeedDiscovery';

export default function feedDiscoveryTest() {
  describe('FeedDiscovery', () => {
    it('discovers_alternate_link', 0, () => {
      const html: string =
        '<html><head><link rel="alternate" type="application/rss+xml" href="/feed.xml"></head></html>';
      const urls: string[] = feedDiscovery.candidateUrls(html, 'https://example.com/blog');
      expect(urls.length).assertEqual(1);
      expect(urls[0]).assertEqual('https://example.com/feed.xml');
    });

    it('keeps_distinct_declared_feeds_for_selection', 0, () => {
      const html: string = '<link rel="alternate" type="application/rss+xml" href="/news.xml">' +
        '<link rel="alternate" type="application/atom+xml" href="/en.xml">' +
        '<link rel="alternate" type="application/rss+xml" href="/news.xml">';
      const urls: string[] = feedDiscovery.candidateUrls(html, 'https://example.com/');
      expect(urls.length).assertEqual(2);
      expect(urls[0]).assertEqual('https://example.com/news.xml');
      expect(urls[1]).assertEqual('https://example.com/en.xml');
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

    it('rejects_html_as_feed', 0, () => {
      expect(isFeedDocument('<html><head><title>Multi Feed</title></head><body></body></html>')).assertFalse();
      expect(isFeedDocument('<!DOCTYPE html><html><body>hi</body></html>')).assertFalse();
    });

    it('accepts_real_feed_documents', 0, () => {
      expect(isFeedDocument('<rss version="2.0"><channel><title>A</title></channel></rss>')).assertTrue();
      expect(isFeedDocument('<feed xmlns="http://www.w3.org/2005/Atom"><title>A</title></feed>')).assertTrue();
      expect(isFeedDocument('{"version":"https://jsonfeed.org/version/1.1","items":[]}')).assertTrue();
    });

    it('rejects_plain_json', 0, () => {
      expect(isFeedDocument('{"title":"not a feed"}')).assertFalse();
    });
  });
}
