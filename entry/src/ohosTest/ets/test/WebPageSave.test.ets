/* 网页稍后读：预览净化、地址校验与同链接去重的设备库验证。 */
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { Article } from '../../../main/ets/model/Feed';
import { BackupArticle } from '../../../main/ets/model/Backup';
import { articleStore, SavedWebPageResult } from '../../../main/ets/service/ArticleStore';
import {
  normalizeWebPageUrl,
  parseWebPagePreview,
  webPageTitle
} from '../../../main/ets/service/WebPageSaveService';
import { WebPagePreview, WEB_PAGE_FEED_ID } from '../../../main/ets/model/WebPagePreview';
import { TestContext } from './TestContext';

const BODY: string =
  '<article><h1>Saved article</h1><p>The quick brown fox jumps over the lazy dog, ' +
  'and then it runs away quietly into the forest.</p><p>Keep this article for later reading.</p>' +
  '<img src="/picture.png"></article>';

export default function webPageSaveTest() {
  describe('WebPageSave', () => {
    it('validates_web_addresses', 0, () => {
      expect(normalizeWebPageUrl('example.com/story')).assertEqual('https://example.com/story');
      expect(normalizeWebPageUrl('javascript:alert(1)')).assertEqual('');
      expect(normalizeWebPageUrl('https://user:pass@example.com/story')).assertEqual('');
    });

    it('previews_title_and_offline_text', 0, () => {
      const html: string = '<html><head><title>Fallback</title>' +
        '<meta property="og:title" content="A &amp; B"></head><body>' + BODY + '</body></html>';
      expect(webPageTitle(html)).assertEqual('A & B');
      const preview: WebPagePreview = parseWebPagePreview('https://example.com/story', html);
      expect(preview.title).assertEqual('A & B');
      expect(preview.source).assertEqual('example.com');
      expect(preview.summary).assertContain('quick brown fox');
      expect(preview.readerHtml.startsWith('<!--hrv9t-->')).assertTrue();
      expect(preview.readerHtml).assertContain('https://example.com/picture.png');
      expect(preview.readerHtml.indexOf('<script')).assertEqual(-1);
    });

    it('reuses_existing_article_and_preserves_saved_body', 0, async () => {
      const injected: common.UIAbilityContext | undefined = TestContext.value;
      const context: common.Context = injected !== undefined
        ? injected : abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      await articleStore.open(context);
      expect(articleStore.dataVersion() > 0).assertTrue();
      const stamp: string = Date.now().toString();
      const link: string = 'https://example.com/saved-web-test/' + stamp;
      const rssId: string = 'saved-web-test-feed|' + link;
      const localId: string = 'saved-web-test-local|' + link;
      try {
        const rss: Article = new Article(rssId, 'saved-web-test-feed', 'Example', 'Existing RSS', link,
          'Existing summary', '', Date.now());
        articleStore.insertNew([rss]);
        const shared: Article = new Article(localId, 'local:saved-web', 'example.com', 'Shared page', link,
          'Shared summary', 'Shared body', Date.now());
        shared.readerHtml = '<!--hrv9-->\n<p>Shared body</p>';
        shared.plainText = 'Shared body';
        const result: SavedWebPageResult | undefined = articleStore.saveWebPage(shared);
        expect(result !== undefined).assertTrue();
        expect(result?.articleId).assertEqual(rssId);
        expect(result?.created).assertFalse();
        const stored: Article | undefined = await articleStore.loadById(rssId);
        expect(stored !== undefined && stored.saved).assertTrue();
        expect(stored?.readerHtml).assertContain('Shared body');
        expect(await articleStore.loadById(localId)).assertEqual(undefined);
      } finally {
        articleStore.deleteMany([rssId, localId]);
      }
    });

    it('creates_standalone_page_only_once', 0, async () => {
      const injected: common.UIAbilityContext | undefined = TestContext.value;
      const context: common.Context = injected !== undefined
        ? injected : abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      await articleStore.open(context);
      const link: string = 'https://example.com/standalone/' + Date.now().toString() +
        '-' + Math.random().toString();
      const id: string = 'saved-web|' + link;
      try {
        expect(await articleStore.loadById(id)).assertEqual(undefined);
        const article: Article = new Article(id, 'local:saved-web', 'example.com', 'Standalone', link,
          'Summary', 'Body', Date.now());
        article.readerHtml = '<!--hrv9--><p>Body</p>';
        article.plainText = 'Body';
        const first: SavedWebPageResult | undefined = articleStore.saveWebPage(article);
        expect(first?.articleId).assertEqual(id);
        const stored: Article | undefined = await articleStore.loadById(id);
        expect(stored?.title).assertEqual('Standalone');
        expect(stored !== undefined && stored.saved).assertTrue();
        expect(first?.created).assertTrue();
        expect(stored?.readerHtml).assertContain('Body');
        const duplicate: Article = new Article('another-id', 'local:saved-web', 'example.com',
          'Standalone copy', link + '?utm_source=share', '', '', Date.now());
        const second: SavedWebPageResult | undefined = articleStore.saveWebPage(duplicate);
        expect(second?.created).assertFalse();
        expect(second?.articleId).assertEqual(id);
        expect(await articleStore.loadById('another-id')).assertEqual(undefined);
      } finally {
        articleStore.deleteMany([id, 'another-id']);
      }
    });

    it('restores_standalone_page_without_feed_subscription', 0, async () => {
      const injected: common.UIAbilityContext | undefined = TestContext.value;
      const context: common.Context = injected !== undefined
        ? injected : abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      await articleStore.open(context);
      const link: string = 'https://example.com/restore/' + Date.now().toString();
      const id: string = 'saved-web|' + link;
      try {
        const backup: BackupArticle = new BackupArticle(id, WEB_PAGE_FEED_ID, 'example.com',
          'Restored web page', link, 'Summary', '', Date.now(), '', false, false, true);
        const merged = await articleStore.mergeArticlesForBackup([backup], []);
        expect(merged.added).assertEqual(1);
        const restored: Article | undefined = await articleStore.loadById(id);
        expect(restored?.title).assertEqual('Restored web page');
        expect(restored?.saved).assertTrue();
      } finally {
        articleStore.deleteMany([id]);
      }
    });
  });
}
