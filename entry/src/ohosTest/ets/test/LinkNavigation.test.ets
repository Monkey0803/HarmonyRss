import { describe, expect, it } from '@ohos/hypium';
import { ArticleLinkTarget, articleLinkTarget, isSameDocumentAnchor,
  isWebLink } from '../../../main/ets/service/LinkNavigation';

export default function linkNavigationTest() {
  describe('LinkNavigation', () => {
    it('only_web_urls_open_in_app', 0, () => {
      expect(isWebLink('https://example.com/page')).assertTrue();
      expect(isWebLink('http://example.com/page')).assertTrue();
      expect(isWebLink('mailto:reader@example.com')).assertFalse();
      expect(isWebLink('javascript:alert(1)')).assertFalse();
      expect(isWebLink('file:///tmp/page.html')).assertFalse();
    });

    it('same_document_anchor_stays_in_article', 0, () => {
      expect(isSameDocumentAnchor('#comments', 'https://example.com/post')).assertTrue();
      expect(isSameDocumentAnchor('https://example.com/post#comments',
        'https://example.com/post')).assertTrue();
      expect(isSameDocumentAnchor('https://example.com/post#second',
        'https://example.com/post#first')).assertTrue();
      expect(isSameDocumentAnchor('https://example.com/other#comments',
        'https://example.com/post')).assertFalse();
      expect(isSameDocumentAnchor('https://example.com/post',
        'https://example.com/post')).assertFalse();
    });

    it('only_user_main_frame_web_click_opens_in_app', 0, () => {
      const current: string = 'https://example.com/post';
      expect(articleLinkTarget('https://another.com/', current, true, true, false))
        .assertEqual(ArticleLinkTarget.IN_APP);
      expect(articleLinkTarget('https://another.com/', current, true, false, false))
        .assertEqual(ArticleLinkTarget.CURRENT);
      expect(articleLinkTarget('https://another.com/', current, true, true, true))
        .assertEqual(ArticleLinkTarget.CURRENT);
      expect(articleLinkTarget('https://another.com/', current, false, true, false))
        .assertEqual(ArticleLinkTarget.CURRENT);
      expect(articleLinkTarget(current + '#comments', current, true, true, false))
        .assertEqual(ArticleLinkTarget.CURRENT);
      expect(articleLinkTarget('javascript:void(0)', current, true, true, false))
        .assertEqual(ArticleLinkTarget.CURRENT);
      expect(articleLinkTarget('mailto:reader@example.com', current, true, true, false))
        .assertEqual(ArticleLinkTarget.SYSTEM);
    });
  });
}
