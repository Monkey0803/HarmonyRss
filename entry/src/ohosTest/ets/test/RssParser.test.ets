/*
 * RssParser.test.ets — RSS 2.0 / Atom 1.0 解析单测。
 */

import { describe, it, expect } from '@ohos/hypium';
import { parseFeed, decodeEntities, stripTags, ParsedFeed, ParsedArticle } from '../../../main/ets/service/RssParser';

const RSS_SAMPLE: string =
  '<?xml version="1.0"?><rss version="2.0"><channel>' +
  '<title>My Feed</title><link>https://example.com</link>' +
  '<item>' +
  '<title>Hello &amp; World</title>' +
  '<link>https://example.com/a</link>' +
  '<description><![CDATA[<p>Summary <b>here</b></p>]]></description>' +
  '<content:encoded><![CDATA[<p>Full body</p><ul><li>one</li></ul>]]></content:encoded>' +
  '<pubDate>Mon, 06 Oct 2025 10:00:00 GMT</pubDate>' +
  '<media:content url="https://example.com/img.jpg"/>' +
  '<dc:creator>Alice</dc:creator>' +
  '</item>' +
  '</channel></rss>';

const ATOM_SAMPLE: string =
  '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">' +
  '<title>Atom Feed</title><link href="https://atom.example"/>' +
  '<entry>' +
  '<title>T</title>' +
  '<link href="https://atom.example/1"/>' +
  '<summary>short summary</summary>' +
  '<updated>2025-10-06T10:00:00Z</updated>' +
  '<author><name>Bob</name></author>' +
  '</entry></feed>';

export default function rssParserTest() {
  describe('RssParser', () => {
    it('decode_entities', 0, () => {
      expect(decodeEntities('&amp;lt;')).assertEqual('&lt;');
      expect(decodeEntities('it&#39;s')).assertEqual('it\'s');
      expect(decodeEntities('&#x41;')).assertEqual('A');
      expect(decodeEntities('a &amp; b')).assertEqual('a & b');
    });

    it('strip_tags', 0, () => {
      expect(stripTags('<p>Hello <b>world</b></p>')).assertEqual('Hello world');
      expect(stripTags('a\n\n  b')).assertEqual('a b');
    });

    it('parses_rss_item', 0, () => {
      const feed: ParsedFeed = parseFeed(RSS_SAMPLE);
      expect(feed.title).assertEqual('My Feed');
      expect(feed.articles.length).assertEqual(1);
      const a: ParsedArticle = feed.articles[0];
      expect(a.title).assertEqual('Hello & World');
      expect(a.link).assertEqual('https://example.com/a');
      expect(a.summary).assertEqual('Summary here');
      expect(a.content).assertEqual('Full body one');
      expect(a.contentHtml).assertContain('<p>Full body</p>');
      expect(a.contentHtml).assertContain('<ul>');
      expect(a.imageUrl).assertEqual('https://example.com/img.jpg');
      expect(a.author).assertEqual('Alice');
      expect(a.publishedAt > 0).assertTrue();
    });

    it('parses_atom_entry', 0, () => {
      const feed: ParsedFeed = parseFeed(ATOM_SAMPLE);
      expect(feed.title).assertEqual('Atom Feed');
      expect(feed.siteUrl).assertEqual('https://atom.example');
      expect(feed.articles.length).assertEqual(1);
      const a: ParsedArticle = feed.articles[0];
      expect(a.title).assertEqual('T');
      expect(a.link).assertEqual('https://atom.example/1');
      expect(a.author).assertEqual('Bob');
      expect(a.publishedAt > 0).assertTrue();
    });

    it('empty_document_is_safe', 0, () => {
      const feed: ParsedFeed = parseFeed('');
      expect(feed.articles.length).assertEqual(0);
      expect(feed.title).assertEqual('');
    });
  });
}
