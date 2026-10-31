import { describe, it, expect } from '@ohos/hypium';
import { ImageCache, InlineImagesResult } from '../../../main/ets/service/ImageCache';
import {
  ArticleContentService,
  readerImageCacheMarker,
  upgradeLegacyReaderCache
} from '../../../main/ets/service/ArticleContentService';
import { Article } from '../../../main/ets/model/Feed';
import { FullTextMode } from '../../../main/ets/common/constants/SettingsConstants';

export default function imageCacheTest() {
  describe('ImageCache', () => {
    it('marks_image_free_article_as_complete', 0, async () => {
      const result: InlineImagesResult = await new ImageCache().inlineImages('<p>Offline article</p>');
      expect(result.remainingRemote).assertEqual(0);
      expect(result.retryable).assertEqual(0);
      expect(readerImageCacheMarker(result.remainingRemote, result.retryable, false)).assertEqual('<!--hrv9-->');
    });

    it('keeps_budget_limited_images_as_partial_without_refetching', 0, async () => {
      let fragment: string = '';
      for (let i = 0; i < 6; i++) {
        fragment += '<img src="data:image/png;base64,AA==">';
      }
      fragment += '<img src="https://example.com/seventh.png">';
      const result: InlineImagesResult = await new ImageCache().inlineImages(fragment);
      expect(result.inlined).assertEqual(6);
      expect(result.remainingRemote).assertEqual(1);
      expect(result.retryable).assertEqual(0);
      expect(result.html.includes('seventh.png')).assertTrue();
      expect(readerImageCacheMarker(result.remainingRemote, result.retryable, false)).assertEqual('<!--hrv9p-->');
    });

    it('retains_retry_marker_after_transient_image_failure', 0, () => {
      expect(readerImageCacheMarker(2, 1, false)).assertEqual('<!--hrv9t-->');
      expect(readerImageCacheMarker(0, 0, true)).assertEqual('<!--hrv9p-->');
    });

    it('upgrades_old_cache_without_dropping_embedded_images', 0, () => {
      const embedded: string = '<img src="data:image/png;base64,AA==">';
      expect(upgradeLegacyReaderCache('<!--hrv8--><p>Story</p>' + embedded))
        .assertEqual('<!--hrv9--><p>Story</p>' + embedded);
      expect(upgradeLegacyReaderCache('<!--hrv8--><p>Story</p>' + embedded +
        '<img src="https://example.com/missing.png">').startsWith('<!--hrv9t-->')).assertTrue();
    });

    it('opens_existing_embedded_images_without_a_network_fetch', 0, async () => {
      const item: Article = new Article('offline-cache-test', 'feed', 'Feed', 'Post', '', '', '', 0, '', '', '');
      item.readerHtml = '<!--hrv8--><p>Saved story</p><img src="data:image/png;base64,AA==">';
      item.plainText = 'Saved story';
      const result: string = await new ArticleContentService().ensureReaderHtml(item, FullTextMode.NEVER);
      expect(result.startsWith('<!--hrv9-->')).assertTrue();
      expect(result.includes('data:image/png;base64,AA==')).assertTrue();
    });
  });
}
