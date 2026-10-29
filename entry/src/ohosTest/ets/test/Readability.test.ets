/*
 * Readability.test.ets — 正文主容器提取单测（启发式，断言关键不变量而非逐字节）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { extractReadable, hasBodyContent } from '../../../main/ets/service/Readability';

const LONG: string =
  'The quick brown fox jumps over the lazy dog, and then it runs away, quietly, into the forest.';
const LONG2: string =
  'Insider trading is illegal in the stock market for a simple reason: it works too well, and people go to prison.';

function page(articleBody: string, extras: string): string {
  return '<html><head><title>x</title></head><body>' +
    extras +
    '<article><h1>Headline</h1>' + articleBody + '</article>' +
    '</body></html>';
}

/** 重复若干段，用于构造「够长」的正文（触发语义容器快路径 / 打分）。 */
function paragraphs(text: string, times: number): string {
  let out: string = '';
  for (let i = 0; i < times; i += 1) {
    out += '<p>' + text + '</p>';
  }
  return out;
}

export default function readabilityTest() {
  describe('Readability', () => {
    it('keeps_article_body', 0, () => {
      const html: string = page('<p>' + LONG + '</p><p>' + LONG2 + '</p>', '');
      const out: string = extractReadable(html, 'https://site.com/post');
      expect(out.length > 0).assertTrue();
      expect(out).assertContain('Headline');
      expect(out).assertContain('quick brown fox');
    });

    it('drops_scripts_and_nav', 0, () => {
      const html: string = page(
        '<p>' + LONG + '</p><p>' + LONG2 + '</p>',
        '<script>bad()</script><nav><a href="/x">menu</a></nav>'
      );
      const out: string = extractReadable(html, 'https://site.com/post');
      expect(out.indexOf('<script')).assertEqual(-1);
      expect(out.indexOf('<nav')).assertEqual(-1);
      expect(out).assertContain('Insider trading');
    });

    it('absolutifies_image_src', 0, () => {
      const html: string = page('<p>' + LONG + '</p><img src="/pic.png"><p>' + LONG2 + '</p>', '');
      const out: string = extractReadable(html, 'https://site.com/post/index.html');
      expect(out).assertContain('https://site.com/pic.png');
    });

    it('recovers_lazy_image_url', 0, () => {
      const html: string = page(
        '<p>' + LONG + '</p><img src="data:image/gif;base64,R0lGOD" data-src="/real.png"><p>' + LONG2 + '</p>',
        ''
      );
      const out: string = extractReadable(html, 'https://site.com/post/index.html');
      expect(out).assertContain('https://site.com/real.png');
    });

    it('falls_back_for_thin_content', 0, () => {
      const out: string = extractReadable('<p>short</p>', '');
      expect(out.length > 0).assertTrue();
      expect(out).assertContain('short');
    });

    it('handles_plain_text_without_tags', 0, () => {
      const out: string = extractReadable('just some plain text with no markup at all', '');
      expect(out.length > 0).assertTrue();
    });

    it('empty_input_is_safe', 0, () => {
      expect(extractReadable('', '')).assertEqual('');
    });

    it('rejects_hn_link_only_description', 0, () => {
      const html: string = '<p>Article URL: <a href="https://example.com/a">https://example.com/a</a></p>' +
        '<p>Comments URL: <a href="https://news.ycombinator.com/item?id=1">' +
        'https://news.ycombinator.com/item?id=1</a></p>' +
        '<p>Points: 21</p><p># Comments: 15</p>';
      expect(hasBodyContent(html)).assertFalse();
    });

    it('accepts_real_feed_body', 0, () => {
      const html: string = '<p>' + LONG + '</p><p>' + LONG2 + '</p>';
      expect(hasBodyContent(html)).assertTrue();
    });

    it('rejects_plain_text_description', 0, () => {
      expect(hasBodyContent(LONG + LONG2)).assertFalse();
    });

    it('prefers_semantic_article_container', 0, () => {
      const html: string = '<html><body>' +
        '<div class="sidebar"><a href="/a">menu one</a><a href="/b">menu two</a>侧栏说明文字。</div>' +
        '<article>' + paragraphs(LONG2, 5) + '</article>' +
        '</body></html>';
      const out: string = extractReadable(html, 'https://site.com/post');
      expect(out).assertContain('Insider trading');
      expect(out.indexOf('menu one')).assertEqual(-1);
    });

    it('drops_trailing_related_block', 0, () => {
      const html: string = '<html><body><article>' + paragraphs(LONG2, 5) +
        '<div class="related"><h3>相关阅读</h3><a href="/x">另一篇文章标题</a></div>' +
        '</article></body></html>';
      const out: string = extractReadable(html, 'https://site.com/post');
      expect(out).assertContain('Insider trading');
      expect(out.indexOf('相关阅读')).assertEqual(-1);
    });

    it('keeps_trailing_media_block', 0, () => {
      const html: string = '<html><body><article>' + paragraphs(LONG2, 5) +
        '<figure><img src="/tail.png"></figure>' +
        '</article></body></html>';
      const out: string = extractReadable(html, 'https://site.com/post/index.html');
      expect(out).assertContain('https://site.com/tail.png');
    });

    it('drops_deep_large_related_list', 0, () => {
      let cards: string = '';
      for (let i = 0; i < 8; i += 1) {
        cards += '<div><a href="/c' + i.toString() + '">观察：第 ' + i.toString() + ' 篇推荐文章标题文字</a></div>';
      }
      const html: string = '<html><body><article><div class="a"><div class="b"><div class="c">' +
        paragraphs(LONG2, 5) + '<div class="rel">' + cards + '</div>' +
        '</div></div></div></article></body></html>';
      const out: string = extractReadable(html, 'https://site.com/post');
      expect(out).assertContain('Insider trading');
      expect(out.indexOf('观察：第')).assertEqual(-1);
    });
  });
}
