/*
 * ShareTargets.test.ets — 分享目标注册表与 URI 构造（纯函数）单测。
 *
 * 覆盖：
 *   - targets：固定顺序与 requiresUrl 标记；
 *   - buildUri：Pocket / Instapaper / Flomo / mailto 的参数与编码（中文、空格、&、#）；
 *   - mailto：subject / body 预填（标题 + 链接 + 摘要截断）；
 *   - 缺链接 / 非 scheme 目标返回空串（调用方据此置灰）。
 *
 * 全部用例只依赖纯函数，不拉起 App、不写剪贴板。
 */

import { describe, it, expect } from '@ohos/hypium';
import { buildUri, encode, ShareTargetId, targetById, targets } from '../../../main/ets/service/ShareTargets';
import { ShareContext, ShareKind, ShareTarget } from '../../../main/ets/model/Share';

/** 普通文章上下文。 */
function articleCtx(): ShareContext {
  return new ShareContext(ShareKind.ARTICLE, 'Hello World', 'https://example.com/a?x=1&y=2',
    'A short summary', 'Alice', ['rss'], 'body', '', '', 'a1', 'Feed');
}

/** 空链接上下文（用于缺 URL 的降级判定）。 */
function noUrlCtx(): ShareContext {
  return new ShareContext(ShareKind.TEXT, 'Only Title');
}

/** 目标的 requiresUrl（未注册按 false 处理，断言不会因 undefined 报错）。 */
function requiresUrlOf(id: string): boolean {
  const target: ShareTarget | undefined = targetById(id);
  return target !== undefined && target.requiresUrl;
}

export default function shareTargetsTest() {
  describe('ShareTargets', () => {
    // ---------- 注册表 ----------

    it('targets_have_fixed_order', 0, () => {
      const list: ShareTarget[] = targets();
      expect(list.length).assertEqual(9);
      expect(list[0].id).assertEqual(ShareTargetId.SYSTEM);
      expect(list[1].id).assertEqual(ShareTargetId.COPY_LINK);
      expect(list[2].id).assertEqual(ShareTargetId.COPY_BODY);
      expect(list[3].id).assertEqual(ShareTargetId.BROWSER);
      expect(list[4].id).assertEqual(ShareTargetId.SAVED);
      expect(list[5].id).assertEqual(ShareTargetId.POCKET);
      expect(list[6].id).assertEqual(ShareTargetId.INSTAPAPER);
      expect(list[7].id).assertEqual(ShareTargetId.FLOMO);
      expect(list[8].id).assertEqual(ShareTargetId.EMAIL);
    });

    it('targets_requires_url_flags', 0, () => {
      // 只有「复制正文」「稍后读」不依赖链接。
      expect(requiresUrlOf(ShareTargetId.COPY_BODY)).assertFalse();
      expect(requiresUrlOf(ShareTargetId.SAVED)).assertFalse();
      expect(requiresUrlOf(ShareTargetId.COPY_LINK)).assertTrue();
      expect(requiresUrlOf(ShareTargetId.POCKET)).assertTrue();
      expect(requiresUrlOf(ShareTargetId.EMAIL)).assertTrue();
    });

    it('targetById_unknown_returns_undefined', 0, () => {
      expect(targetById('nope') === undefined).assertTrue();
    });

    // ---------- 编码 ----------

    it('encode_escapes_special_chars', 0, () => {
      expect(encode('a b')).assertEqual('a%20b');
      expect(encode('中')).assertEqual('%E4%B8%AD');
      expect(encode('a&b=c#d')).assertEqual('a%26b%3Dc%23d');
    });

    // ---------- 各目标 URL ----------

    it('pocket_uri_encodes_url_and_title', 0, () => {
      expect(buildUri(ShareTargetId.POCKET, articleCtx()))
        .assertEqual('pocket://add?url=https%3A%2F%2Fexample.com%2Fa%3Fx%3D1%26y%3D2&title=Hello%20World');
    });

    it('instapaper_uri_uses_x_callback_url', 0, () => {
      expect(buildUri(ShareTargetId.INSTAPAPER, articleCtx()))
        .assertEqual('instapaper://x-callback-url/add?url=https%3A%2F%2Fexample.com%2Fa%3Fx%3D1%26y%3D2' +
          '&title=Hello%20World');
    });

    it('flomo_uri_joins_title_and_url', 0, () => {
      // 内容 = 「标题 + 换行 + 链接」，整体编码。
      expect(buildUri(ShareTargetId.FLOMO, articleCtx()))
        .assertEqual('flomo://create?content=Hello%20World%0Ahttps%3A%2F%2Fexample.com%2Fa%3Fx%3D1%26y%3D2');
    });

    it('flomo_uri_without_title_uses_url_only', 0, () => {
      const ctx: ShareContext = new ShareContext(ShareKind.TEXT, '', 'https://e.com/p');
      expect(buildUri(ShareTargetId.FLOMO, ctx)).assertEqual('flomo://create?content=https%3A%2F%2Fe.com%2Fp');
    });

    it('mailto_prefills_subject_and_body', 0, () => {
      const uri: string = buildUri(ShareTargetId.EMAIL, articleCtx());
      expect(uri.startsWith('mailto:?subject=Hello%20World&body=')).assertTrue();
      // 正文 = 标题 / 链接 / 摘要，段落之间空行。
      expect(uri).assertEqual('mailto:?subject=Hello%20World&body=Hello%20World%0A%0A' +
        'https%3A%2F%2Fexample.com%2Fa%3Fx%3D1%26y%3D2%0A%0AA%20short%20summary');
    });

    it('mailto_body_skips_empty_summary', 0, () => {
      const ctx: ShareContext = new ShareContext(ShareKind.TEXT, 'T', 'https://e.com/p');
      expect(buildUri(ShareTargetId.EMAIL, ctx))
        .assertEqual('mailto:?subject=T&body=T%0A%0Ahttps%3A%2F%2Fe.com%2Fp');
    });

    it('mailto_body_truncates_summary_with_ellipsis', 0, () => {
      const longSummary: string = 's'.repeat(400);
      const ctx: ShareContext = new ShareContext(ShareKind.ARTICLE, 'T', 'https://e.com/p', longSummary);
      const uri: string = buildUri(ShareTargetId.EMAIL, ctx);
      // 300 字符 + 省略号：摘要被截断（编码后不会出现 400 个 s）。
      expect(uri.indexOf('s'.repeat(301)) < 0).assertTrue();
      expect(uri.indexOf('ssss')).assertTrue();
    });

    // ---------- 缺链接 / 不支持 ----------

    it('build_uri_empty_without_url', 0, () => {
      expect(buildUri(ShareTargetId.POCKET, noUrlCtx())).assertEqual('');
      expect(buildUri(ShareTargetId.INSTAPAPER, noUrlCtx())).assertEqual('');
      expect(buildUri(ShareTargetId.FLOMO, noUrlCtx())).assertEqual('');
      expect(buildUri(ShareTargetId.EMAIL, noUrlCtx())).assertEqual('');
    });

    it('build_uri_empty_for_non_scheme_targets', 0, () => {
      expect(buildUri(ShareTargetId.SYSTEM, articleCtx())).assertEqual('');
      expect(buildUri(ShareTargetId.COPY_LINK, articleCtx())).assertEqual('');
      expect(buildUri(ShareTargetId.COPY_BODY, articleCtx())).assertEqual('');
      expect(buildUri(ShareTargetId.BROWSER, articleCtx())).assertEqual('');
      expect(buildUri(ShareTargetId.SAVED, articleCtx())).assertEqual('');
    });
  });
}
