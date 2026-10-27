/*
 * ShareTemplates.test.ets — 分享模板渲染 / 校验 / 编解码（纯函数）单测。
 *
 * 覆盖：
 *   - render：五个占位符替换、重复占位符全部替换、未知占位符原样保留、空字段不产生 undefined；
 *   - validate：空名称 / 空内容 / 超长名称 / 超长内容；
 *   - decodeTemplates / encodeTemplates：脏数据丢弃、sort 归一、编码时按顺序重排；
 *   - sortTemplates / defaultTemplate：升序排序与默认模板内容。
 *
 * 全部用例只依赖纯函数，不打开偏好库、不发网络请求。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  decodeTemplates,
  defaultTemplate,
  encodeTemplates,
  render,
  sortTemplates,
  validate
} from '../../../main/ets/service/ShareTemplates';
import { ShareContext, ShareKind, ShareTemplate } from '../../../main/ets/model/Share';
import { CommonConstants } from '../../../main/ets/common/constants/CommonConstants';

/** 一篇文章的分享上下文（五个占位符都有值）。 */
function articleCtx(): ShareContext {
  return new ShareContext(ShareKind.ARTICLE, 'Hello World', 'https://example.com/a?x=1&y=2',
    'A short summary', 'Alice', ['rss', 'reading'], 'body text', '', '', 'a1', 'Feed');
}

export default function shareTemplatesTest() {
  describe('ShareTemplates', () => {
    // ---------- render ----------

    it('render_replaces_all_known_tokens', 0, () => {
      const template: ShareTemplate = new ShareTemplate('t1', 'n',
        '{title} | {url} | {summary} | {author} | {tags}', 0);
      expect(render(template, articleCtx()))
        .assertEqual('Hello World | https://example.com/a?x=1&y=2 | A short summary | Alice | rss, reading');
    });

    it('render_replaces_repeated_tokens', 0, () => {
      const template: ShareTemplate = new ShareTemplate('t1', 'n', '{title}-{title}', 0);
      expect(render(template, articleCtx())).assertEqual('Hello World-Hello World');
    });

    it('render_keeps_unknown_tokens', 0, () => {
      // 未知占位符原样保留（需求：忽略未知占位符 = 保留原文）。
      const template: ShareTemplate = new ShareTemplate('t1', 'n', '{title} {unknown} {tags}', 0);
      expect(render(template, articleCtx())).assertEqual('Hello World {unknown} rss, reading');
    });

    it('render_empty_fields_produce_empty_text', 0, () => {
      const ctx: ShareContext = new ShareContext(ShareKind.HIGHLIGHT, '', '', '', '', [], '', 'quote', '', 'a1', '');
      const template: ShareTemplate = new ShareTemplate('t1', 'n', '[{title}][{url}][{tags}]', 0);
      expect(render(template, ctx)).assertEqual('[][][]');
    });

    it('render_highlight_tags_is_empty_string', 0, () => {
      const ctx: ShareContext = new ShareContext(ShareKind.HIGHLIGHT, 'T', 'https://e.com', '', '', [],
        'body', 'quote', 'note', 'a1', 'Feed');
      const template: ShareTemplate = new ShareTemplate('t1', 'n', '{tags}', 0);
      expect(render(template, ctx)).assertEqual('');
    });

    // ---------- validate ----------

    it('validate_rejects_empty', 0, () => {
      expect(validate('', 'content')).assertEqual('tpl_err_name_empty');
      expect(validate('   ', 'content')).assertEqual('tpl_err_name_empty');
      expect(validate('name', '')).assertEqual('tpl_err_content_empty');
      expect(validate('name', '   ')).assertEqual('tpl_err_content_empty');
    });

    it('validate_rejects_too_long', 0, () => {
      const longName: string = 'n'.repeat(CommonConstants.SHARE_TEMPLATE_NAME_MAX + 1);
      const longContent: string = 'c'.repeat(CommonConstants.SHARE_TEMPLATE_CONTENT_MAX + 1);
      expect(validate(longName, 'content')).assertEqual('tpl_err_name_long');
      expect(validate('name', longContent)).assertEqual('tpl_err_content_long');
    });

    it('validate_accepts_boundary_values', 0, () => {
      const maxName: string = 'n'.repeat(CommonConstants.SHARE_TEMPLATE_NAME_MAX);
      const maxContent: string = 'c'.repeat(CommonConstants.SHARE_TEMPLATE_CONTENT_MAX);
      expect(validate(maxName, maxContent)).assertEqual('');
    });

    // ---------- 编解码 ----------

    it('decode_drops_invalid_records', 0, () => {
      const raw: string = '[{"id":"","name":"n","content":"c","sort":0},' +
        '{"id":"t2","name":"","content":"c","sort":0},' +
        '{"id":"t3","name":"n","content":"","sort":0},' +
        '{"id":"t4","name":"ok","content":"c","sort":0}]';
      const items: ShareTemplate[] = decodeTemplates(raw);
      expect(items.length).assertEqual(1);
      expect(items[0].id).assertEqual('t4');
    });

    it('decode_invalid_json_returns_empty', 0, () => {
      expect(decodeTemplates('not json').length).assertEqual(0);
      expect(decodeTemplates('').length).assertEqual(0);
    });

    it('encode_renumbers_sort_by_order', 0, () => {
      const items: ShareTemplate[] = [
        new ShareTemplate('a', 'A', 'x', 7),
        new ShareTemplate('b', 'B', 'y', 3)
      ];
      const decoded: ShareTemplate[] = decodeTemplates(encodeTemplates(items));
      expect(decoded.length).assertEqual(2);
      // 落盘顺序即展示顺序，sort 被重排为下标。
      expect(decoded[0].id).assertEqual('a');
      expect(decoded[0].sort).assertEqual(0);
      expect(decoded[1].sort).assertEqual(1);
    });

    it('sort_is_ascending_stable', 0, () => {
      const items: ShareTemplate[] = [
        new ShareTemplate('c', 'C', 'x', 2),
        new ShareTemplate('a', 'A', 'x', 0),
        new ShareTemplate('b', 'B', 'x', 1)
      ];
      const sorted: ShareTemplate[] = sortTemplates(items);
      expect(sorted[0].id).assertEqual('a');
      expect(sorted[1].id).assertEqual('b');
      expect(sorted[2].id).assertEqual('c');
      // 不修改入参顺序。
      expect(items[0].id).assertEqual('c');
    });

    it('default_template_is_title_then_url', 0, () => {
      const template: ShareTemplate = defaultTemplate();
      expect(template.content).assertEqual('{title}\n{url}');
      expect(render(template, articleCtx()))
        .assertEqual('Hello World\nhttps://example.com/a?x=1&y=2');
    });
  });
}
