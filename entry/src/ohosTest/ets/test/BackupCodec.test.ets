/*
 * BackupCodec.test.ets — 备份编解码 / 合并决策 / 白名单 / 导出裁剪的纯逻辑单测。
 *
 * 覆盖：
 *   - serialize → parse 往返（各数据段与设置）；
 *   - 版本不匹配 / 空串 / 坏 JSON / 非对象一律返回 undefined；
 *   - 未知字段忽略、缺失数组给空、脏行跳过；
 *   - mergeArticleState 状态并集（read/starred/saved/hidden OR，进度 max，canonicalId 保留旧值）；
 *   - settingsWhitelist / isSettingsKeyAllowed（含 themeMode / dedupeEnabled，不含 backgroundImagePath）；
 *   - sanitizeFeed / sanitizeArticle 丢弃 ETag、正文缓存等设备相关 / 体积敏感字段。
 *
 * 全部用例只调用纯函数，不打开文件或数据库。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  isSettingsKeyAllowed,
  mergeArticleState,
  parse,
  sanitizeArticle,
  sanitizeFeed,
  serialize,
  settingsWhitelist
} from '../../../main/ets/service/BackupCodec';
import {
  ArticleStatePatch,
  BackupArticle,
  BackupArticleTag,
  BackupDocument,
  BackupFeed,
  BackupHighlight,
  BackupRule,
  BackupSmartFolder,
  BackupTag,
  BackupTemplate
} from '../../../main/ets/model/Backup';
import { Article, FeedSource } from '../../../main/ets/model/Feed';

/** 一个装满各数据段的备份文档（往返用例）。 */
function buildFullDocument(): BackupDocument {
  const doc: BackupDocument = new BackupDocument();
  doc.exportedAt = 1700000000000;
  doc.app = 'HarmonyRss';
  doc.settings.set('themeMode', 'dark');
  doc.settings.set('dedupeEnabled', true);
  doc.feeds.push(new BackupFeed('https://a.com/feed', 'A', 'https://a.com', 'Tech', false, 60,
    'always', 30, 'off', 'on'));
  doc.articles.push(new BackupArticle('a1', 'https://a.com/feed', 'A', 'Title',
    'https://a.com/p1', 'Summary', 'Author', 1700000000000, 'https://a.com/i.png', true, true,
    true, false, 120, 0.5, '', 'link-key', 'title-key'));
  doc.highlights.push(new BackupHighlight('h1', 'a1', 'Quote', 'Note', '#ffcc00',
    1700000000000, 'anchor', 0.25));
  doc.tags.push(new BackupTag('t1', '新闻', 1700000000000));
  doc.articleTags.push(new BackupArticleTag('a1', 't1'));
  doc.smartFolders.push(new BackupSmartFolder('f1', '未读技术', 'from:tech is:unread', 1));
  doc.rules.push(new BackupRule('r1', '规则', true, 2, ['AI', '模型'], ['title'],
    ['https://a.com/feed'], ['star'], ['t1'], 9, 1700000000000));
  doc.templates.push(new BackupTemplate('m1', '默认', '{title} {url}', 0));
  return doc;
}

export default function backupCodecTest() {
  describe('BackupCodec', () => {
    // ---------- 序列化 / 解析 ----------

    it('serialize_parse_roundtrip', 0, () => {
      const text: string = serialize(buildFullDocument());
      expect(text.length > 0).assertTrue();
      const doc: BackupDocument | undefined = parse(text);
      expect(doc !== undefined).assertTrue();
      if (doc === undefined) {
        return;
      }
      expect(doc.version).assertEqual(1);
      expect(doc.exportedAt).assertEqual(1700000000000);
      expect(doc.app).assertEqual('HarmonyRss');
      expect(doc.settings.get('themeMode')).assertEqual('dark');
      expect(doc.settings.get('dedupeEnabled')).assertTrue();
      expect(doc.feeds.length).assertEqual(1);
      expect(doc.feeds[0].url).assertEqual('https://a.com/feed');
      expect(doc.feeds[0].fullTextMode).assertEqual('always');
      expect(doc.feeds[0].fetchIntervalMinutes).assertEqual(60);
      expect(doc.articles.length).assertEqual(1);
      expect(doc.articles[0].id).assertEqual('a1');
      expect(doc.articles[0].saved).assertTrue();
      expect(doc.articles[0].progress).assertEqual(120);
      expect(doc.articles[0].progressRatio).assertEqual(0.5);
      expect(doc.articles[0].linkKey).assertEqual('link-key');
      expect(doc.highlights.length).assertEqual(1);
      expect(doc.highlights[0].quote).assertEqual('Quote');
      expect(doc.tags.length).assertEqual(1);
      expect(doc.articleTags.length).assertEqual(1);
      expect(doc.smartFolders.length).assertEqual(1);
      expect(doc.smartFolders[0].query).assertEqual('from:tech is:unread');
      expect(doc.rules.length).assertEqual(1);
      expect(doc.rules[0].keywords.length).assertEqual(2);
      expect(doc.rules[0].matchCount).assertEqual(9);
      expect(doc.templates.length).assertEqual(1);
      expect(doc.templates[0].content).assertEqual('{title} {url}');
    });

    it('version_mismatch_rejected', 0, () => {
      expect(parse('{"version":2,"feeds":[]}') === undefined).assertTrue();
      // 缺 version 视作 0，同样拒绝。
      expect(parse('{"feeds":[]}') === undefined).assertTrue();
      expect(parse('{"version":"x","feeds":[]}') === undefined).assertTrue();
    });

    it('empty_or_bad_json_rejected', 0, () => {
      expect(parse('') === undefined).assertTrue();
      expect(parse('   ') === undefined).assertTrue();
      expect(parse('not json') === undefined).assertTrue();
      expect(parse('null') === undefined).assertTrue();
      expect(parse('[]') === undefined).assertTrue();
    });

    it('unknown_fields_ignored', 0, () => {
      const text: string = '{"version":1,"mystery":123,"feeds":[],"articles":[],' +
        '"highlights":[],"tags":[],"articleTags":[],"smartFolders":[],"rules":[],"templates":[],' +
        '"settings":{"themeMode":"light","unknownKey":"x"},"anotherUnknown":{"a":1}}';
      const doc: BackupDocument | undefined = parse(text);
      expect(doc !== undefined).assertTrue();
      if (doc === undefined) {
        return;
      }
      expect(doc.feeds.length).assertEqual(0);
      expect(doc.settings.get('themeMode')).assertEqual('light');
      // 未在白名单里的设置键被丢弃。
      expect(doc.settings.get('unknownKey') === undefined).assertTrue();
    });

    it('missing_arrays_become_empty', 0, () => {
      const doc: BackupDocument | undefined = parse('{"version":1}');
      expect(doc !== undefined).assertTrue();
      if (doc === undefined) {
        return;
      }
      expect(doc.feeds.length).assertEqual(0);
      expect(doc.articles.length).assertEqual(0);
      expect(doc.highlights.length).assertEqual(0);
      expect(doc.tags.length).assertEqual(0);
      expect(doc.articleTags.length).assertEqual(0);
      expect(doc.smartFolders.length).assertEqual(0);
      expect(doc.rules.length).assertEqual(0);
      expect(doc.templates.length).assertEqual(0);
      expect(doc.settings.keys().length).assertEqual(0);
      expect(doc.app).assertEqual('HarmonyRss');
      expect(doc.exportedAt).assertEqual(0);
    });

    it('dirty_rows_skipped', 0, () => {
      const text: string = '{"version":1,"feeds":[{"title":"no url"},{"url":"https://ok.com/feed"}],' +
        '"articles":[{"title":"no id"},{"id":"a1"}],"tags":[{"id":"t1"},{"id":"t2","name":"X"}]}';
      const doc: BackupDocument | undefined = parse(text);
      expect(doc !== undefined).assertTrue();
      if (doc === undefined) {
        return;
      }
      expect(doc.feeds.length).assertEqual(1);
      expect(doc.feeds[0].url).assertEqual('https://ok.com/feed');
      expect(doc.articles.length).assertEqual(1);
      expect(doc.articles[0].id).assertEqual('a1');
      expect(doc.tags.length).assertEqual(1);
      expect(doc.tags[0].name).assertEqual('X');
    });

    // ---------- 状态合并 ----------

    it('merge_article_state_union', 0, () => {
      const existing: ArticleStatePatch = new ArticleStatePatch(false, true, false, false,
        10, 0.2, 'old-canonical');
      const incoming: ArticleStatePatch = new ArticleStatePatch(true, false, true, true,
        50, 0.8, 'new-canonical');
      const merged: ArticleStatePatch = mergeArticleState(existing, incoming);
      // 四个布尔状态取并集。
      expect(merged.read).assertTrue();
      expect(merged.starred).assertTrue();
      expect(merged.saved).assertTrue();
      expect(merged.hidden).assertTrue();
      // 进度取最大。
      expect(merged.progress).assertEqual(50);
      expect(merged.progressRatio).assertEqual(0.8);
      // 旧库已有主条关系时不被打断。
      expect(merged.canonicalId).assertEqual('old-canonical');
    });

    it('merge_article_state_keeps_incoming_canonical_when_existing_empty', 0, () => {
      const existing: ArticleStatePatch = new ArticleStatePatch(true, false, false, false,
        0, 0, '');
      const incoming: ArticleStatePatch = new ArticleStatePatch(false, false, false, false,
        0, 0, 'incoming-canonical');
      expect(mergeArticleState(existing, incoming).canonicalId).assertEqual('incoming-canonical');
      // 双向幂等：同值再合并一次结果不变。
      const once: ArticleStatePatch = mergeArticleState(existing, incoming);
      expect(mergeArticleState(once, incoming).canonicalId).assertEqual('incoming-canonical');
    });

    // ---------- 设置白名单 ----------

    it('settings_whitelist_expected_keys', 0, () => {
      const list: string[] = settingsWhitelist();
      expect(list.indexOf('themeMode') >= 0).assertTrue();
      expect(list.indexOf('dedupeEnabled') >= 0).assertTrue();
      // 设备路径不进备份。
      expect(list.indexOf('backgroundImagePath') < 0).assertTrue();
      expect(isSettingsKeyAllowed('themeMode')).assertTrue();
      expect(isSettingsKeyAllowed('dedupeEnabled')).assertTrue();
      expect(isSettingsKeyAllowed('backgroundImagePath')).assertFalse();
      expect(isSettingsKeyAllowed('password')).assertFalse();
      expect(isSettingsKeyAllowed('notARealKey')).assertFalse();
    });

    it('settings_whitelist_returns_copy', 0, () => {
      const list: string[] = settingsWhitelist();
      list.push('backgroundImagePath');
      // 修改返回值不污染全局白名单。
      expect(isSettingsKeyAllowed('backgroundImagePath')).assertFalse();
    });

    // ---------- 导出裁剪 ----------

    it('sanitize_feed_drops_device_fields', 0, () => {
      const feed: FeedSource = new FeedSource('https://a.com/feed', 'A', 'https://a.com/feed',
        'https://a.com', 'Tech');
      feed.etag = 'ETAG_SECRET';
      feed.lastModified = 'LM_SECRET';
      feed.failureCount = 3;
      feed.lastUpdated = 1700000000000;
      feed.articleCount = 42;
      feed.unreadCount = 7;
      feed.lastError = 'ERROR_SECRET';
      feed.enabled = false;
      feed.fetchIntervalMinutes = 30;
      feed.fullTextMode = 'never';
      feed.retentionDays = 90;
      feed.notify = 'off';
      feed.markReadOnScroll = 'on';
      const out: BackupFeed = sanitizeFeed(feed);
      expect(out.url).assertEqual('https://a.com/feed');
      expect(out.title).assertEqual('A');
      expect(out.group).assertEqual('Tech');
      expect(out.enabled).assertFalse();
      expect(out.fetchIntervalMinutes).assertEqual(30);
      expect(out.fullTextMode).assertEqual('never');
      expect(out.retentionDays).assertEqual(90);
      expect(out.notify).assertEqual('off');
      expect(out.markReadOnScroll).assertEqual('on');
      const json: string = JSON.stringify(out);
      expect(json.indexOf('ETAG_SECRET') < 0).assertTrue();
      expect(json.indexOf('LM_SECRET') < 0).assertTrue();
      expect(json.indexOf('ERROR_SECRET') < 0).assertTrue();
      expect(json.indexOf('etag') < 0).assertTrue();
      expect(json.indexOf('lastModified') < 0).assertTrue();
      expect(json.indexOf('failureCount') < 0).assertTrue();
    });

    it('sanitize_feed_falls_back_to_id', 0, () => {
      const feed: FeedSource = new FeedSource('https://a.com/feed', 'A', '', '');
      feed.url = '';
      expect(sanitizeFeed(feed).url).assertEqual('https://a.com/feed');
    });

    it('sanitize_article_drops_body_fields', 0, () => {
      const article: Article = new Article('a1', 'https://a.com/feed', 'A', 'Title',
        'https://a.com/p1', 'SUMMARY_OK', 'BODY_SECRET', 1700000000000, 'https://a.com/i.png',
        'AUTHOR_OK', '<p>HTML_SECRET</p>');
      article.readerHtml = 'READER_SECRET';
      article.readerState = 'ready';
      article.plainText = 'PLAIN_SECRET';
      article.pageEtag = 'PAGE_ETAG_SECRET';
      article.pageLastModified = 'PAGE_LM_SECRET';
      article.duplicateCount = 3;
      article.read = true;
      article.starred = true;
      article.saved = true;
      article.hidden = true;
      article.progress = 88;
      article.progressRatio = 0.44;
      article.canonicalId = 'canonical-1';
      article.linkKey = 'link-key';
      article.titleKey = 'title-key';
      const out: BackupArticle = sanitizeArticle(article);
      expect(out.id).assertEqual('a1');
      expect(out.feedId).assertEqual('https://a.com/feed');
      expect(out.title).assertEqual('Title');
      expect(out.summary).assertEqual('SUMMARY_OK');
      expect(out.author).assertEqual('AUTHOR_OK');
      expect(out.publishedAt).assertEqual(1700000000000);
      expect(out.imageUrl).assertEqual('https://a.com/i.png');
      // 阅读状态与去重键保留。
      expect(out.read).assertTrue();
      expect(out.starred).assertTrue();
      expect(out.saved).assertTrue();
      expect(out.hidden).assertTrue();
      expect(out.progress).assertEqual(88);
      expect(out.progressRatio).assertEqual(0.44);
      expect(out.canonicalId).assertEqual('canonical-1');
      expect(out.linkKey).assertEqual('link-key');
      expect(out.titleKey).assertEqual('title-key');
      // 正文缓存 / ETag / 派生字段全部丢弃。
      const json: string = JSON.stringify(out);
      expect(json.indexOf('BODY_SECRET') < 0).assertTrue();
      expect(json.indexOf('HTML_SECRET') < 0).assertTrue();
      expect(json.indexOf('READER_SECRET') < 0).assertTrue();
      expect(json.indexOf('PLAIN_SECRET') < 0).assertTrue();
      expect(json.indexOf('PAGE_ETAG_SECRET') < 0).assertTrue();
      expect(json.indexOf('PAGE_LM_SECRET') < 0).assertTrue();
      expect(json.indexOf('contentHtml') < 0).assertTrue();
      expect(json.indexOf('readerHtml') < 0).assertTrue();
      expect(json.indexOf('plainText') < 0).assertTrue();
      expect(json.indexOf('pageEtag') < 0).assertTrue();
      expect(json.indexOf('duplicateCount') < 0).assertTrue();
    });
  });
}
