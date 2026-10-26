/*
 * BackupMerge.test.ets — 备份订阅合并的纯逻辑单测。
 *
 * 覆盖：
 *   - mergeFeedsForBackup：按归一化 URL 去重（scheme / host 大小写、末尾斜杠）、
 *     保留本地独有订阅、备份新增字段生效、非法 URL 跳过、备份内重复只留第一条；
 *   - 幂等：同一 incoming 连续合并两次结果一致；
 *   - 空备份 / 空本地边界。
 *
 * 全部用例只调用 FeedStore 导出的纯函数，不打开 preferences 或数据库。
 */

import { describe, it, expect } from '@ohos/hypium';
import { feedMergeKey, mergeFeedsForBackup } from '../../../main/ets/service/FeedStore';
import { BackupFeed } from '../../../main/ets/model/Backup';
import { FeedSource } from '../../../main/ets/model/Feed';
import { FullTextMode, TriState } from '../../../main/ets/common/constants/SettingsConstants';

/** 本地订阅。 */
function localFeed(url: string, title: string): FeedSource {
  return new FeedSource(url, title, url, 'https://site.example', 'Group');
}

/** 备份订阅（默认全部跟随全局）。 */
function backupFeed(url: string, title: string = ''): BackupFeed {
  return new BackupFeed(url, title, '', '');
}

/** 取合并结果里的 URL 列表（便于断言顺序）。 */
function urlsOf(feeds: FeedSource[]): string {
  const parts: string[] = [];
  for (let i = 0; i < feeds.length; i += 1) {
    parts.push(feeds[i].url);
  }
  return parts.join('|');
}

export default function backupMergeTest() {
  describe('BackupMerge', () => {
    // ---------- 合并键 ----------

    it('merge_key_normalizes_case_and_trailing_slash', 0, () => {
      const a: string = feedMergeKey('https://Example.com/feed/', 'id-a');
      const b: string = feedMergeKey('https://example.com/feed', 'id-b');
      expect(a).assertEqual(b);
      expect(a).assertEqual('https://example.com/feed');
    });

    it('merge_key_falls_back_to_id_when_url_empty', 0, () => {
      expect(feedMergeKey('', 'https://Fallback.com/rss')).assertEqual('https://fallback.com/rss');
      expect(feedMergeKey('   ', '')).assertEqual('');
    });

    // ---------- 去重 ----------

    it('dedupes_case_and_trailing_slash_against_local', 0, () => {
      const local: FeedSource[] = [localFeed('https://Example.com/feed/', '本地标题')];
      const incoming: BackupFeed[] = [backupFeed('https://example.com/feed', '备份标题')];
      const merged: FeedSource[] = mergeFeedsForBackup(local, incoming);
      // 归一化后视为同一订阅：不新增，且保留本地标题 / 源实例。
      expect(merged.length).assertEqual(1);
      expect(merged[0].title).assertEqual('本地标题');
      expect(merged[0].url).assertEqual('https://Example.com/feed/');
    });

    it('dedupes_duplicates_inside_incoming', 0, () => {
      const incoming: BackupFeed[] = [
        backupFeed('https://Duplicate.com/feed/', '第一条'),
        backupFeed('https://duplicate.com/feed', '第二条'),
        backupFeed('https://other.com/feed', '另一个')
      ];
      const merged: FeedSource[] = mergeFeedsForBackup([], incoming);
      expect(merged.length).assertEqual(2);
      expect(merged[0].url).assertEqual('https://Duplicate.com/feed/');
      expect(merged[0].title).assertEqual('第一条');
      expect(merged[1].url).assertEqual('https://other.com/feed');
    });

    it('keeps_local_only_feeds', 0, () => {
      const local: FeedSource[] = [
        localFeed('https://a.com/feed', 'A'),
        localFeed('https://b.com/feed', 'B')
      ];
      const incoming: BackupFeed[] = [
        backupFeed('https://a.com/feed', 'A backup'),
        backupFeed('https://c.com/feed', 'C')
      ];
      const merged: FeedSource[] = mergeFeedsForBackup(local, incoming);
      expect(merged.length).assertEqual(3);
      // 本地顺序不变，新订阅追加在末尾。
      expect(urlsOf(merged)).assertEqual('https://a.com/feed|https://b.com/feed|https://c.com/feed');
      expect(merged[0].title).assertEqual('A');
      expect(merged[1].title).assertEqual('B');
      expect(merged[2].title).assertEqual('C');
      // 入参不被修改。
      expect(local.length).assertEqual(2);
    });

    // ---------- 新字段 ----------

    it('applies_backup_fields_to_new_feed', 0, () => {
      const incoming: BackupFeed[] = [new BackupFeed('https://new.com/feed', 'New',
        'https://new.com', '科技', false, 60, FullTextMode.ALWAYS, 30, TriState.OFF,
        TriState.ON)];
      const merged: FeedSource[] = mergeFeedsForBackup([], incoming);
      expect(merged.length).assertEqual(1);
      const feed: FeedSource = merged[0];
      expect(feed.url).assertEqual('https://new.com/feed');
      expect(feed.title).assertEqual('New');
      expect(feed.siteUrl).assertEqual('https://new.com');
      expect(feed.group).assertEqual('科技');
      expect(feed.enabled).assertFalse();
      expect(feed.fetchIntervalMinutes).assertEqual(60);
      expect(feed.fullTextMode).assertEqual(FullTextMode.ALWAYS);
      expect(feed.retentionDays).assertEqual(30);
      expect(feed.notify).assertEqual(TriState.OFF);
      expect(feed.markReadOnScroll).assertEqual(TriState.ON);
    });

    it('normalizes_dirty_backup_fields', 0, () => {
      const incoming: BackupFeed[] = [new BackupFeed('https://dirty.com/feed', 'Dirty',
        '', '', true, 7, 'weird', 42, 'yes', 'maybe')];
      const feed: FeedSource = mergeFeedsForBackup([], incoming)[0];
      expect(feed.fetchIntervalMinutes).assertEqual(0);
      expect(feed.fullTextMode).assertEqual(FullTextMode.GLOBAL);
      expect(feed.retentionDays).assertEqual(0);
      expect(feed.notify).assertEqual(TriState.GLOBAL);
      expect(feed.markReadOnScroll).assertEqual(TriState.GLOBAL);
    });

    it('title_falls_back_to_url_when_missing', 0, () => {
      const feed: FeedSource = mergeFeedsForBackup([], [backupFeed('https://x.com/feed')])[0];
      expect(feed.title).assertEqual('https://x.com/feed');
    });

    // ---------- 非法 / 边界 ----------

    it('skips_invalid_urls', 0, () => {
      const incoming: BackupFeed[] = [
        backupFeed(''),
        backupFeed('   '),
        backupFeed('not a url'),
        backupFeed('ftp://a.com/feed'),
        backupFeed('javascript:alert(1)'),
        backupFeed('https://ok.com/feed', 'OK')
      ];
      const merged: FeedSource[] = mergeFeedsForBackup([], incoming);
      expect(merged.length).assertEqual(1);
      expect(merged[0].url).assertEqual('https://ok.com/feed');
    });

    it('empty_backup_returns_local_copy', 0, () => {
      const local: FeedSource[] = [localFeed('https://a.com/feed', 'A')];
      const merged: FeedSource[] = mergeFeedsForBackup(local, []);
      expect(merged.length).assertEqual(1);
      expect(urlsOf(merged)).assertEqual('https://a.com/feed');
      // 返回新数组，不共享引用。
      expect(merged !== local).assertTrue();
    });

    it('empty_local_accepts_all_backup_feeds', 0, () => {
      const incoming: BackupFeed[] = [
        backupFeed('https://a.com/feed', 'A'),
        backupFeed('https://b.com/feed', 'B')
      ];
      const merged: FeedSource[] = mergeFeedsForBackup([], incoming);
      expect(merged.length).assertEqual(2);
      expect(urlsOf(merged)).assertEqual('https://a.com/feed|https://b.com/feed');
    });

    it('idempotent_repeated_merge', 0, () => {
      const local: FeedSource[] = [localFeed('https://a.com/feed', 'A')];
      const incoming: BackupFeed[] = [
        backupFeed('https://b.com/feed', 'B'),
        backupFeed('https://c.com/feed/', 'C')
      ];
      const first: FeedSource[] = mergeFeedsForBackup(local, incoming);
      const second: FeedSource[] = mergeFeedsForBackup(first, incoming);
      expect(first.length).assertEqual(3);
      expect(second.length).assertEqual(3);
      expect(urlsOf(second)).assertEqual(urlsOf(first));
      expect(second[0].title).assertEqual(first[0].title);
      expect(second[1].title).assertEqual(first[1].title);
      expect(second[2].title).assertEqual(first[2].title);
    });
  });
}
