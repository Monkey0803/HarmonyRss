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
  SyncKeys,
  SyncKinds,
  SyncRecord,
  TagPayload,
  decodeArticleTagPayload,
  decodeHighlightPayload,
  decodeTagPayload,
  encodeArticleTagPayload,
  encodeHighlightPayload,
  encodeTagPayload,
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
