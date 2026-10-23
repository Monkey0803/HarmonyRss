/*
 * DedupeKeys.test.ets — 跨源去重归一化键（纯函数）单测。
 *
 * 覆盖：
 *   - urlKey：跟踪参数（utm_* / fbclid / gclid / ref / source）剔除、fragment 剔除、
 *     host 大小写归一（path / query 大小写保留）、末尾斜杠、query 相对顺序保留、非法串回退；
 *   - titleKey：大小写、全角 / 半角标点、空白、空串；
 *   - sameTitleWindow：0 值 fallback、±24h 边界（含等于）、超出窗口不匹配。
 *
 * 全部用例只依赖 DedupeKeys 的静态纯函数，不打开数据库、不发网络请求。
 */

import { describe, it, expect } from '@ohos/hypium';
import { DedupeKeys } from '../../../main/ets/service/DedupeKeys';

/** 24 小时（毫秒），与 RssConstants.DEDUPE_WINDOW_MS 一致。 */
const DAY_MS: number = 24 * 60 * 60 * 1000;
/** 一小时（毫秒），构造窗口内外的偏移用。 */
const HOUR_MS: number = 60 * 60 * 1000;

export default function dedupeKeysTest() {
  describe('DedupeKeys', () => {
    // ---------- urlKey ----------

    it('urlKey_drops_tracking_params', 0, () => {
      // utm_* 前缀与 fbclid / gclid / ref / source 都只影响追踪，不应参与「是否同一篇」的判断。
      expect(DedupeKeys.urlKey('https://example.com/post?utm_source=weibo')).assertEqual('https://example.com/post');
      expect(DedupeKeys.urlKey('https://example.com/post?utm_medium=rss&utm_campaign=daily'))
        .assertEqual('https://example.com/post');
      expect(DedupeKeys.urlKey('https://example.com/post?fbclid=abc')).assertEqual('https://example.com/post');
      expect(DedupeKeys.urlKey('https://example.com/post?gclid=abc')).assertEqual('https://example.com/post');
      expect(DedupeKeys.urlKey('https://example.com/post?ref=homepage')).assertEqual('https://example.com/post');
      expect(DedupeKeys.urlKey('https://example.com/post?source=rss')).assertEqual('https://example.com/post');
      // 大写键名同样剔除（键按小写比较）。
      expect(DedupeKeys.urlKey('https://example.com/post?UTM_Source=x&FBCLID=y'))
        .assertEqual('https://example.com/post');
    });

    it('urlKey_keeps_real_params_in_original_order', 0, () => {
      // 只剔除追踪参数，其余参数保持原始相对顺序（不排序、不重编码）。
      expect(DedupeKeys.urlKey('https://example.com/p?id=7&utm_source=x&page=2'))
        .assertEqual('https://example.com/p?id=7&page=2');
      expect(DedupeKeys.urlKey('https://example.com/p?z=1&a=2'))
        .assertEqual('https://example.com/p?z=1&a=2');
      // 参数值里的大小写不能被改掉。
      expect(DedupeKeys.urlKey('https://example.com/p?q=HelloWorld'))
        .assertEqual('https://example.com/p?q=HelloWorld');
    });

    it('urlKey_drops_fragment', 0, () => {
      // 同一文章的锚点（章节 / 评论定位）不应产生不同键。
      expect(DedupeKeys.urlKey('https://example.com/post#comments')).assertEqual('https://example.com/post');
      expect(DedupeKeys.urlKey('https://example.com/post?id=1#part2')).assertEqual('https://example.com/post?id=1');
      expect(DedupeKeys.urlKey('https://example.com/post#a')).assertEqual(DedupeKeys.urlKey('https://example.com/post#b'));
    });

    it('urlKey_normalizes_host_case_only', 0, () => {
      // scheme / host 小写；path 与 query 的大小写是站点语义的一部分，必须保留。
      expect(DedupeKeys.urlKey('HTTPS://Example.COM/Post')).assertEqual('https://example.com/Post');
      expect(DedupeKeys.urlKey('https://EXAMPLE.com/Post')).assertEqual('https://example.com/Post');
      // path 大小写不同 ⇒ 认为不是同一页面。
      expect(DedupeKeys.urlKey('https://example.com/Post') === DedupeKeys.urlKey('https://example.com/post'))
        .assertFalse();
      // 首尾空白在解析前被裁掉。
      expect(DedupeKeys.urlKey('  https://Example.com/Post  ')).assertEqual('https://example.com/Post');
    });

    it('urlKey_strips_trailing_slash', 0, () => {
      // 末尾斜杠差异（含多个斜杠）归一。
      expect(DedupeKeys.urlKey('https://example.com/post/')).assertEqual(DedupeKeys.urlKey('https://example.com/post'));
      expect(DedupeKeys.urlKey('https://example.com/post///')).assertEqual('https://example.com/post');
      // 根路径归一为空。
      expect(DedupeKeys.urlKey('https://example.com/')).assertEqual('https://example.com');
      expect(DedupeKeys.urlKey('https://example.com')).assertEqual('https://example.com');
    });

    it('urlKey_combines_all_normalizations', 0, () => {
      // 真实场景：转载方加了追踪参数、锚点、末尾斜杠、大写 host。
      const a: string = DedupeKeys.urlKey('HTTPS://Example.COM/Archives/2024/post/?utm_source=rss#top');
      const b: string = DedupeKeys.urlKey('https://example.com/Archives/2024/post');
      expect(a).assertEqual(b);
      expect(a).assertEqual('https://example.com/Archives/2024/post');
    });

    it('urlKey_invalid_url_falls_back', 0, () => {
      // 空串 ⇒ 空键（调用方据此跳过 URL 维度）。
      expect(DedupeKeys.urlKey('')).assertEqual('');
      expect(DedupeKeys.urlKey('   ')).assertEqual('');
      // 非 URL 串解析失败 ⇒ 退回「去空白 + 小写」原串，保证同串同键、不抛异常。
      expect(DedupeKeys.urlKey('  Not A URL  ')).assertEqual('not a url');
      expect(DedupeKeys.urlKey('not a url')).assertEqual(DedupeKeys.urlKey('NOT A URL'));
      // 相对地址没有 scheme，同样走回退分支且保持幂等。
      const once: string = DedupeKeys.urlKey('Articles/2024/Post.HTML');
      expect(once).assertEqual(DedupeKeys.urlKey(once));
    });

    // ---------- titleKey ----------

    it('titleKey_normalizes_case', 0, () => {
      expect(DedupeKeys.titleKey('Hello World')).assertEqual('helloworld');
      expect(DedupeKeys.titleKey('HELLO WORLD')).assertEqual('helloworld');
      expect(DedupeKeys.titleKey('hello world')).assertEqual('helloworld');
    });

    it('titleKey_drops_whitespace', 0, () => {
      // 首尾空白、连续空格、制表符、全角空格都属于排版噪声。
      expect(DedupeKeys.titleKey('  Hello   World  ')).assertEqual('helloworld');
      expect(DedupeKeys.titleKey('Hello\tWorld')).assertEqual('helloworld');
      expect(DedupeKeys.titleKey('Hello\u3000World')).assertEqual('helloworld');
      expect(DedupeKeys.titleKey('Hello\nWorld')).assertEqual('helloworld');
    });

    it('titleKey_treats_fullwidth_and_halfwidth_punctuation_alike', 0, () => {
      const expected: string = 'ai芯片的新进展';
      expect(DedupeKeys.titleKey('AI，芯片的新进展')).assertEqual(expected);
      expect(DedupeKeys.titleKey('AI, 芯片的新进展')).assertEqual(expected);
      // 中文书名号 / 引号 / 顿号 / 冒号 / 感叹号等都被剔除。
      expect(DedupeKeys.titleKey('《AI：芯片的新进展！')).assertEqual(expected);
      expect(DedupeKeys.titleKey('\u201cAI\u201d，芯片的新进展。')).assertEqual(expected);
      // 半角连字符 / 下划线 / 斜杠也算标点。
      expect(DedupeKeys.titleKey('AI-Chip_New/Progress')).assertEqual('aichipnewprogress');
    });

    it('titleKey_empty_input_returns_empty_key', 0, () => {
      expect(DedupeKeys.titleKey('')).assertEqual('');
      expect(DedupeKeys.titleKey('   ')).assertEqual('');
      // 全部由标点组成 ⇒ 归一后为空键（不参与标题匹配）。
      expect(DedupeKeys.titleKey('！！！。。。')).assertEqual('');
      expect(DedupeKeys.titleKey('---___')).assertEqual('');
    });

    // ---------- sameTitleWindow ----------

    it('sameTitleWindow_uses_fallback_when_timestamp_missing', 0, () => {
      const base: number = 1700000000000;
      // 两边都缺失 ⇒ 都用 fallback ⇒ 同一窗口内。
      expect(DedupeKeys.sameTitleWindow(0, 0, base)).assertTrue();
      // 只有一边缺失 ⇒ 用 fallback 代入比较。
      expect(DedupeKeys.sameTitleWindow(0, base + HOUR_MS, base)).assertTrue();
      expect(DedupeKeys.sameTitleWindow(base - HOUR_MS, 0, base)).assertTrue();
      // 缺失的一边代入 fallback 后仍可能超出窗口。
      expect(DedupeKeys.sameTitleWindow(0, base + 2 * DAY_MS, base)).assertFalse();
      // 不给 fallback 时默认用当前时间：两个都缺失必然同窗口。
      expect(DedupeKeys.sameTitleWindow(0, 0)).assertTrue();
    });

    it('sameTitleWindow_boundary_is_inclusive', 0, () => {
      const base: number = 1700000000000;
      // ±24h 边界本身算匹配（<=）。
      expect(DedupeKeys.sameTitleWindow(base, base + DAY_MS)).assertTrue();
      expect(DedupeKeys.sameTitleWindow(base, base - DAY_MS)).assertTrue();
      // 差 1ms 即超出窗口。
      expect(DedupeKeys.sameTitleWindow(base, base + DAY_MS + 1)).assertFalse();
      expect(DedupeKeys.sameTitleWindow(base, base - DAY_MS - 1)).assertFalse();
      // 与入参顺序无关。
      expect(DedupeKeys.sameTitleWindow(base + DAY_MS, base)).assertTrue();
      // 同一时间必然匹配。
      expect(DedupeKeys.sameTitleWindow(base, base)).assertTrue();
    });
  });
}
