/*
 * HtmlSanitizer.test.ets — 净化器 / URL 解析单测。
 */

import { describe, it, expect } from '@ohos/hypium';
import { parseHtml, HtmlNode } from '../../../main/ets/service/HtmlDom';
import { sanitizeFragment, resolveUrl, escapeHtml } from '../../../main/ets/service/HtmlSanitizer';

function sanitize(html: string, base: string = ''): string {
  const root: HtmlNode = parseHtml(html);
  return sanitizeFragment(root, base);
}

export default function htmlSanitizerTest() {
  describe('HtmlSanitizer', () => {
    it('resolves_relative_urls', 0, () => {
      expect(resolveUrl('https://a.com/b/c.html', 'img/x.png')).assertEqual('https://a.com/b/img/x.png');
      expect(resolveUrl('https://a.com/b/', '//cdn.com/z.png')).assertEqual('https://cdn.com/z.png');
      expect(resolveUrl('https://a.com/b/c', '/root.png')).assertEqual('https://a.com/root.png');
      expect(resolveUrl('https://a.com/b/c', '../up.png')).assertEqual('https://a.com/up.png');
    });

    it('keeps_absolute_urls_untouched', 0, () => {
      expect(resolveUrl('https://a.com/', 'https://b.com/x')).assertEqual('https://b.com/x');
      expect(resolveUrl('https://a.com/', 'data:image/png;base64,AAAA')).assertEqual('data:image/png;base64,AAAA');
    });

    it('drops_script_but_keeps_siblings', 0, () => {
      expect(sanitize('<div><script>bad()</script><p>ok</p></div>')).assertEqual('<div><p>ok</p></div>');
    });

    it('drops_javascript_href', 0, () => {
      expect(sanitize('<a href="javascript:alert(1)">x</a>')).assertEqual('<a>x</a>');
    });

    it('unwraps_unknown_tags', 0, () => {
      expect(sanitize('<custom-tag><p>keep</p></custom-tag>')).assertEqual('<p>keep</p>');
    });

    it('absolutifies_img_src', 0, () => {
      const out: string = sanitize('<img src="/a.png">', 'https://site.com/post');
      expect(out).assertContain('src="https://site.com/a.png"');
      expect(out).assertContain('loading="lazy"');
    });

    it('decodes_then_escapes_entities_once', 0, () => {
      // 源里已有 &#39; 实体，输出应是可直接显示的撇号，不能是 &amp;#39;。
      expect(sanitize('<p>it&#39;s</p>')).assertEqual('<p>it\'s</p>');
    });

    it('escapes_plain_markup_chars', 0, () => {
      // 文本里的 &lt; 实体解码成 '<' 后再被转义回 &lt;，保证只解码一次、转义一次。
      expect(sanitize('<p>a &lt; b</p>')).assertEqual('<p>a &lt; b</p>');
    });

    it('escape_html_basics', 0, () => {
      expect(escapeHtml('<a>&"')).assertEqual('&lt;a&gt;&amp;&quot;');
    });

    it('prefers_data_src_over_placeholder', 0, () => {
      const out: string = sanitize('<img src="data:image/gif;base64,R0lGOD" data-src="/real.png">', 'https://s.com/p');
      expect(out).assertContain('src="https://s.com/real.png"');
    });

    it('falls_back_to_data_original', 0, () => {
      const out: string = sanitize('<img src="" data-original="/o.png">', 'https://s.com/p');
      expect(out).assertContain('src="https://s.com/o.png"');
    });

    it('uses_srcset_first_candidate', 0, () => {
      const out: string = sanitize('<img srcset="/a.png 1x, /b.png 2x">', 'https://s.com/p');
      expect(out).assertContain('src="https://s.com/a.png"');
    });

    it('keeps_alt_and_title', 0, () => {
      const out: string = sanitize('<img src="/x.png" alt="pic" title="t">', 'https://s.com/p');
      expect(out).assertContain('alt="pic"');
      expect(out).assertContain('title="t"');
      expect(out).assertContain('loading="lazy"');
    });

    it('drops_picture_source_but_keeps_img', 0, () => {
      const out: string = sanitize('<picture><source srcset="/hi.webp"><img src="/lo.jpg"></picture>', 'https://s.com/p');
      expect(out.indexOf('<source')).assertEqual(-1);
      expect(out).assertContain('src="https://s.com/lo.jpg"');
    });

    it('unwraps_image_only_link', 0, () => {
      const out: string = sanitize('<a href="/post"><img src="/p.png"></a>', 'https://s.com/a');
      expect(out.indexOf('<a')).assertEqual(-1);
      expect(out).assertContain('src="https://s.com/p.png"');
      // 带文字的链接照常保留。
      expect(sanitize('<a href="/x">text</a>')).assertEqual('<a href="/x">text</a>');
    });

    it('normalizes_text_only_div_to_paragraph', 0, () => {
      expect(sanitize('<div>plain text</div>')).assertEqual('<p>plain text</p>');
      // 含块级子节点的 div 保持容器语义（不把块塞进 p）。
      expect(sanitize('<div><p>a</p><p>b</p></div>')).assertEqual('<div><p>a</p><p>b</p></div>');
    });

    it('drops_blank_paragraphs_and_containers', 0, () => {
      expect(sanitize('<p> </p><div></div><p>ok</p>')).assertEqual('<p>ok</p>');
      // 只剩被丢弃的元素（svg / script）也视为空段落。
      expect(sanitize('<p><svg></svg> </p><p>ok</p>')).assertEqual('<p>ok</p>');
      // 有视觉内容的容器要保留：分隔线 / 图片不算空块。
      expect(sanitize('<div><hr></div>')).assertEqual('<div><hr></div>');
      expect(sanitize('<p><img src="/a.png"></p>', 'https://s.com/p')).assertContain('<img');
    });
  });
}
