import { describe, it, expect } from '@ohos/hypium';
import { Article } from '../../../main/ets/model/Feed';
import { FullTextMode } from '../../../main/ets/common/constants/SettingsConstants';
import { ArticleContentService } from '../../../main/ets/service/ArticleContentService';
import { isReaderPlaceholder } from '../../../main/ets/service/ReaderContentGuard';
import { extractReadable } from '../../../main/ets/service/Readability';

const MASTODON: string = '<p>To use the Mastodon web application, please enable JavaScript.</p>' +
  '<p>Alternatively, try one of the <a href="/apps">native apps</a> for Mastodon for your platform.</p>';
const POST: string = '<p>Anthropic got compromised. Their Claude Code extension has malware in it, ' +
  'which creates a remote access Trojan to desktops.</p>';
const FULL_POST: string = POST + '<p>This is a longer discussion of the reported issue and its possible effects ' +
  'on developer workstations.</p>';
const YOUTUBE_FOOTER: string = '<!--hrv8t--><a href="https://www.youtube.com/about/">簡介</a>' +
  '<a href="https://www.youtube.com/t/terms">條款</a><p>© 2026 Google LLC</p>';
const YOUTUBE_URL: string = 'https://www.youtube.com/watch?v=MENoB3Rex28';

function article(contentHtml: string): Article {
  return new Article('guard-test', 'feed', 'Feed', 'Post', '', '', '', 0, '', '', contentHtml);
}

export default function readerContentGuardTest() {
  describe('ReaderContentGuard', () => {
    it('recognizes_mastodon_placeholder', 0, () => {
      expect(isReaderPlaceholder(MASTODON)).assertTrue();
      expect(isReaderPlaceholder('<!--hrv8t-->' + MASTODON)).assertTrue();
      expect(isReaderPlaceholder('<!--hrv8-->' + MASTODON)).assertTrue();
    });

    it('keeps_real_posts_and_articles_about_javascript', 0, () => {
      expect(isReaderPlaceholder(POST)).assertFalse();
      expect(isReaderPlaceholder('<p>To use the Mastodon web application, please enable JavaScript.</p>' +
        '<p>This is a guide explaining why that message appears and how readers can fix it.</p>')).assertFalse();
      expect(isReaderPlaceholder('<article><p>Enable JavaScript to continue using this site.</p>' +
        '<p>This article compares static and dynamic rendering for accessibility.</p></article>')).assertFalse();
    });

    it('recognizes_extracted_placeholder', 0, () => {
      const extracted: string = extractReadable('<html><body>' + MASTODON + '</body></html>', '');
      expect(isReaderPlaceholder(extracted)).assertTrue();
    });

    it('recognizes_youtube_footer_only_for_watch_page', 0, () => {
      expect(isReaderPlaceholder(YOUTUBE_FOOTER, YOUTUBE_URL)).assertTrue();
      expect(isReaderPlaceholder(YOUTUBE_FOOTER, 'https://example.com/article')).assertFalse();
      expect(isReaderPlaceholder('<p>A video review of YouTube terms and Google LLC.</p>',
        YOUTUBE_URL)).assertFalse();
    });

    it('reextracts_instead_of_returning_bad_cache', 0, async () => {
      const item: Article = article(FULL_POST);
      item.readerHtml = '<!--hrv8-->' + MASTODON;
      item.plainText = 'To use the Mastodon web application, please enable JavaScript.';
      const service: ArticleContentService = new ArticleContentService();
      const result: string = await service.ensureReaderHtml(item, FullTextMode.NEVER);
      expect(result.indexOf('Anthropic got compromised') >= 0).assertTrue();
      expect(result.indexOf('please enable JavaScript') < 0).assertTrue();
    });
  });
}
