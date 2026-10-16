/*
 * HtmlDom.test.ets — HtmlDom 解析器单测（本地单元测试，纯函数无依赖）。
 */

import { describe, it, expect } from '@ohos/hypium';
import { parseHtml, findFirst, textContent, HtmlNode } from '../../../main/ets/service/HtmlDom';

export default function htmlDomTest() {
  describe('HtmlDom', () => {
    it('parses_tag_and_attrs', 0, () => {
      const root: HtmlNode = parseHtml('<div class="a" id="b">hi</div>');
      const div: HtmlNode | undefined = findFirst(root, 'div');
      expect(div !== undefined).assertTrue();
      if (div !== undefined) {
        expect(div.attr('class')).assertEqual('a');
        expect(div.attr('id')).assertEqual('b');
      }
    });

    it('void_element_has_no_children', 0, () => {
      const root: HtmlNode = parseHtml('<img src="x"><p>y</p>');
      const img: HtmlNode | undefined = findFirst(root, 'img');
      expect(img !== undefined).assertTrue();
      if (img !== undefined) {
        expect(img.attr('src')).assertEqual('x');
        expect(img.children.length).assertEqual(0);
      }
      expect(textContent(root)).assertEqual('y');
    });

    it('script_raw_text_does_not_break_parsing', 0, () => {
      // 脚本里的 '<' 不应把解析带偏，后面的 <p> 仍要能识别。
      const root: HtmlNode = parseHtml('<script>if (a<b) { x(); }</script><p>z</p>');
      expect(textContent(root)).assertEqual('z');
    });

    it('unclosed_tags_close_by_stack', 0, () => {
      const root: HtmlNode = parseHtml('<ul><li>a<li>b</ul>');
      const ul: HtmlNode | undefined = findFirst(root, 'ul');
      expect(ul !== undefined).assertTrue();
      if (ul !== undefined) {
        expect(ul.children.length).assertEqual(2);
      }
      expect(textContent(root)).assertEqual('ab');
    });

    it('cdata_becomes_text', 0, () => {
      const root: HtmlNode = parseHtml('<p><![CDATA[<x>]]></p>');
      expect(textContent(root)).assertEqual('<x>');
    });

    it('comment_is_skipped', 0, () => {
      const root: HtmlNode = parseHtml('<p>a<!-- hidden -->b</p>');
      expect(textContent(root)).assertEqual('ab');
    });
  });
}
