/* Serialize deferred inline image work after reader text is already visible. */
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
import { imageCache, InlineImagesResult } from './ImageCache';
import { ReaderBudget } from './ReaderBudget';
import { NetworkStatus } from './NetworkStatus';

const DOMAIN: number = 0x0000;
const TAG: string = 'ArticleContentService';
const INLINE_DELAY_MS: number = 2000;

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

export class ReaderInlineQueue {
  private inlineQueue: Promise<void> = Promise.resolve();
  private inlineScheduled: Map<string, string> = new Map<string, string>();
  private persistResult: (article: Article, fragment: string, plain: string) => void;
  private markerFor: (remainingRemote: number, retryable: number, budgetRejected: boolean) => string;
  private textMarker: string;

  constructor(persistResult: (article: Article, fragment: string, plain: string) => void,
    markerFor: (remainingRemote: number, retryable: number, budgetRejected: boolean) => string,
    textMarker: string) {
    this.persistResult = persistResult;
    this.markerFor = markerFor;
    this.textMarker = textMarker;
  }

  /**
   * 排队把正文图片内联为 data URI（离线可读）。
   * 串行执行：预取与当前文章可能同时具备补图条件，并行下载只会互相抢带宽。
   * 延迟 INLINE_DELAY_MS 再开始，让首屏先渲染出来。
   */
  schedule(article: Article, fresh: string, plain: string): void {
    const token: string = this.textMarker + fresh;
    if (!NetworkStatus.isOnline() || this.inlineScheduled.get(article.id) === token) {
      return;
    }
    this.inlineScheduled.set(article.id, token);
    this.inlineQueue = this.inlineQueue
      .then(() => this.inlineLater(article, fresh, plain, token))
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'inline queue failed: %{public}d', err.code);
      });
  }

  /** 后台补图：只在正文未被替换（重提取 / 切文）时写回。 */
  private async inlineLater(article: Article, fresh: string, plain: string, token: string): Promise<void> {
    try {
      await delay(INLINE_DELAY_MS);
      if (article.readerHtml !== token) {
        return;
      }
      const start: number = Date.now();
      const result: InlineImagesResult = await imageCache.inlineImages(fresh);
      if (article.readerHtml !== token) {
        return;
      }
      // 最后一道总预算：超限则退回未内联的正文，保证单篇体积有界。
      const fitted: string = ReaderBudget.fit(fresh, result.html);
      const budgetRejected: boolean = fitted !== result.html;
      const marker: string = this.markerFor(result.remainingRemote, result.retryable, budgetRejected);
      const fragment: string = marker + fitted;
      if (fragment === token) {
        // 全部下载失败且仍可重试；保留文本标记，下一次联网打开再补。
        return;
      }
      hilog.info(DOMAIN, TAG, 'perf inline=%{public}dms inlined=%{public}d chars',
        Date.now() - start, fragment.length);
      this.persistResult(article, fragment, plain);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'inline images failed: %{public}d', error.code);
    } finally {
      if (this.inlineScheduled.get(article.id) === token) {
        this.inlineScheduled.delete(article.id);
      }
    }
  }

}
