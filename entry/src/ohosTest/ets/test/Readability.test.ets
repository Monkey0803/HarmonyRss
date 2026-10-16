/*
 * Readability.test.ets — 正文主容器提取单测（启发式，断言关键不变量而非逐字节）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { extractReadable } from '../../../main/ets/service/Readability';

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
  });
}
