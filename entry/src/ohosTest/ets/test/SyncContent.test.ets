/*
 * SyncContent.test.ets — 高亮 / 标签 / 关联 / 设置的同步载荷与键单测。
 *
 * 覆盖：载荷编码往返、脏数据拒绝（缺 id / 缺名称 / 缺关联键）、
 * 稳定键构造，以及非文章状态实体仍按整条记录后写胜出（墓碑同样参与比较）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ArticleTagPayload,
  HighlightPayload,
  RulePayload,
  SmartFolderPayload,
  SyncKeys,
  SyncKinds,
  SyncRecord,
  TagPayload,
  TemplatePayload,
  decodeArticleTagPayload,
  decodeHighlightPayload,
  decodeRulePayload,
  decodeSmartFolderPayload,
  decodeTagPayload,
  decodeTemplatePayload,
  encodeArticleTagPayload,
  encodeHighlightPayload,
  encodeRulePayload,
  encodeSmartFolderPayload,
  encodeTagPayload,
  encodeTemplatePayload,
  mergeRecord
} from '../../../main/ets/model/Sync';

export default function syncContentTest() {
  describe('SyncContent', () => {
    // ---------- 键 ----------

    it('keys_are_stable', 0, () => {
      expect(SyncKeys.highlightKey('h1')).assertEqual('highlight:h1');
      expect(SyncKeys.tagKey('ai')).assertEqual('tag:ai');
      expect(SyncKeys.articleTagKey('ai', 'a1')).assertEqual('articleTag:ai|a1');
      expect(SyncKeys.SETTINGS).assertEqual('setting:app');
    });

    // ---------- 高亮 ----------

    it('highlight_roundtrip', 0, () => {
      const payload = new HighlightPayload('h1', 'a1', '引文', '备注', 'yellow',
        1700000000000, '上下文', 0.42);
      const restored: HighlightPayload | undefined =
        decodeHighlightPayload(encodeHighlightPayload(payload));
      expect(restored !== undefined).assertTrue();
      if (restored === undefined) {
        return;
      }
      expect(restored.id).assertEqual('h1');
      expect(restored.articleId).assertEqual('a1');
      expect(restored.quote).assertEqual('引文');
      expect(restored.note).assertEqual('备注');
      expect(restored.color).assertEqual('yellow');
      expect(restored.createdAt).assertEqual(1700000000000);
      expect(restored.anchorText).assertEqual('上下文');
      expect(restored.anchorRatio).assertEqual(0.42);
    });

    it('highlight_rejects_missing_ids', 0, () => {
      expect(decodeHighlightPayload('') === undefined).assertTrue();
      expect(decodeHighlightPayload('not json') === undefined).assertTrue();
      // 缺 articleId：无法判断落在哪篇文章上，直接丢弃。
      expect(decodeHighlightPayload('{"id":"h1","articleId":"","quote":"x"}') === undefined).assertTrue();
      expect(decodeHighlightPayload('{"id":"","articleId":"a1"}') === undefined).assertTrue();
    });

    it('highlight_missing_optional_fields_fall_back', 0, () => {
      const restored: HighlightPayload | undefined =
        decodeHighlightPayload('{"id":"h1","articleId":"a1"}');
      expect(restored !== undefined).assertTrue();
      if (restored === undefined) {
        return;
      }
      expect(restored.quote).assertEqual('');
      expect(restored.note).assertEqual('');
      expect(restored.color).assertEqual('');
      expect(restored.createdAt).assertEqual(0);
      expect(restored.anchorRatio).assertEqual(0);
    });

    // ---------- 标签 ----------

    it('tag_roundtrip', 0, () => {
      const restored: TagPayload | undefined =
        decodeTagPayload(encodeTagPayload(new TagPayload('AI')));
      expect(restored !== undefined).assertTrue();
      if (restored === undefined) {
        return;
      }
      expect(restored.name).assertEqual('AI');
    });

    it('tag_rejects_empty_name', 0, () => {
      expect(decodeTagPayload('{"name":""}') === undefined).assertTrue();
      expect(decodeTagPayload('') === undefined).assertTrue();
      expect(decodeTagPayload('{oops}') === undefined).assertTrue();
    });

    // ---------- 文章 ↔ 标签 ----------

    it('article_tag_roundtrip', 0, () => {
      const restored: ArticleTagPayload | undefined = decodeArticleTagPayload(
        encodeArticleTagPayload(new ArticleTagPayload('a1', 'ai', 'AI')));
      expect(restored !== undefined).assertTrue();
      if (restored === undefined) {
        return;
      }
      expect(restored.articleId).assertEqual('a1');
      expect(restored.nameKey).assertEqual('ai');
      expect(restored.name).assertEqual('AI');
    });

    it('article_tag_rejects_incomplete', 0, () => {
      expect(decodeArticleTagPayload('{"articleId":"a1","nameKey":"ai"}') === undefined).assertTrue();
      expect(decodeArticleTagPayload('{"articleId":"a1","name":"AI"}') === undefined).assertTrue();
      expect(decodeArticleTagPayload('{"nameKey":"ai","name":"AI"}') === undefined).assertTrue();
    });

    // ---------- 智能文件夹 / 规则 / 模板 ----------

    it('smart_folder_roundtrip', 0, () => {
      const restored: SmartFolderPayload | undefined = decodeSmartFolderPayload(
        encodeSmartFolderPayload(new SmartFolderPayload('AI 日报', 'is:unread after:2026-01-01')));
      expect(restored !== undefined).assertTrue();
      if (restored === undefined) {
        return;
      }
      expect(restored.name).assertEqual('AI 日报');
      expect(restored.query).assertEqual('is:unread after:2026-01-01');
      expect(decodeSmartFolderPayload('{"name":""}') === undefined).assertTrue();
    });

    it('template_roundtrip', 0, () => {
      const restored: TemplatePayload | undefined = decodeTemplatePayload(
        encodeTemplatePayload(new TemplatePayload('Flomo', '{title} {url}')));
      expect(restored !== undefined).assertTrue();
      if (restored === undefined) {
        return;
      }
      expect(restored.name).assertEqual('Flomo');
      expect(restored.content).assertEqual('{title} {url}');
      expect(decodeTemplatePayload('{"name":""}') === undefined).assertTrue();
    });

    it('rule_roundtrip_keeps_references', 0, () => {
      const restored: RulePayload | undefined = decodeRulePayload(encodeRulePayload(
        new RulePayload('AI 规则', true, ['ai', 'gpt'], ['title'], ['star'],
          ['https://a.com/feed'], ['AI'])));
      expect(restored !== undefined).assertTrue();
      if (restored === undefined) {
        return;
      }
      expect(restored.name).assertEqual('AI 规则');
      expect(restored.enabled).assertTrue();
      expect(restored.keywords.length).assertEqual(2);
      expect(restored.fields[0]).assertEqual('title');
      expect(restored.actions[0]).assertEqual('star');
      expect(restored.feedKeys[0]).assertEqual('https://a.com/feed');
      expect(restored.tagNames[0]).assertEqual('AI');
    });

    it('rule_rejects_missing_name_and_filters_bad_arrays', 0, () => {
      expect(decodeRulePayload('{"name":""}') === undefined).assertTrue();
      // 数组里混入非字符串项：只保留合法项，不整体丢弃。
      const restored: RulePayload | undefined = decodeRulePayload(
        '{"name":"r","enabled":true,"keywords":["a","",3],"fields":null}');
      expect(restored !== undefined).assertTrue();
      if (restored === undefined) {
        return;
      }
      expect(restored.keywords.length).assertEqual(1);
      expect(restored.fields.length).assertEqual(0);
      expect(restored.actions.length).assertEqual(0);
    });

    it('name_keys_normalize', 0, () => {
      expect(SyncKeys.nameKey('  AI 日报 ')).assertEqual('ai 日报');
      expect(SyncKeys.smartFolderKey('ai')).assertEqual('smartFolder:ai');
      expect(SyncKeys.ruleKey('ai')).assertEqual('rule:ai');
      expect(SyncKeys.templateKey('ai')).assertEqual('template:ai');
    });

    // ---------- 整条记录后写胜出 ----------

    it('content_kinds_use_last_write_wins', 0, () => {
      const older: SyncRecord = new SyncRecord('tag:ai', SyncKinds.TAG, 100, false,
        encodeTagPayload(new TagPayload('AI')), 'node-a');
      const newer: SyncRecord = new SyncRecord('tag:ai', SyncKinds.TAG, 200, false,
        encodeTagPayload(new TagPayload('AI 2')), 'node-b');
      const merged: SyncRecord = mergeRecord(older, newer);
      expect(merged.payload).assertEqual(newer.payload);
      expect(merged.updatedAt).assertEqual(200);
    });

    it('content_tombstone_wins_when_newer', 0, () => {
      const alive: SyncRecord = new SyncRecord('highlight:h1', SyncKinds.HIGHLIGHT, 100, false,
        encodeHighlightPayload(new HighlightPayload('h1', 'a1', 'q', '', 'yellow', 1, '', 0)),
        'node-a');
      const tombstone: SyncRecord = new SyncRecord('highlight:h1', SyncKinds.HIGHLIGHT, 200,
        true, '', 'node-b');
      expect(mergeRecord(alive, tombstone).deleted).assertTrue();
      expect(mergeRecord(tombstone, alive).deleted).assertTrue();
    });
  });
}
