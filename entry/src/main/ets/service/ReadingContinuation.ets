import { AbilityConstant, Want } from '@kit.AbilityKit';
import { Article } from '../model/Feed';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { normalizeWebPageUrl } from './WebPageSaveService';

const CONTINUE_VERSION: string = 'hr.continue.version';
const CONTINUE_ID: string = 'hr.continue.articleId';
const CONTINUE_URL: string = 'hr.continue.url';
const CONTINUE_RATIO: string = 'hr.continue.ratio';

export class ContinueRequest {
  readonly articleId: string;
  readonly url: string;
  readonly ratio: number;

  constructor(articleId: string, url: string, ratio: number) {
    this.articleId = articleId;
    this.url = url;
    this.ratio = ratio;
  }
}

/** 只传轻量阅读状态；跨设备不传正文、缓存文件或认证信息。 */
export class ReadingContinuation {
  private detailVisible: boolean = false;
  private pending: ContinueRequest | undefined = undefined;

  setDetailVisible(visible: boolean): void {
    this.detailVisible = visible;
  }

  write(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    const article: Article | undefined = this.detailVisible ? feedViewModel.currentArticle() : undefined;
    if (article === undefined) {
      return AbilityConstant.OnContinueResult.REJECT;
    }
    const url: string = normalizeWebPageUrl(article.link);
    if (url.length === 0) {
      return AbilityConstant.OnContinueResult.REJECT;
    }
    wantParam[CONTINUE_VERSION] = 1;
    wantParam[CONTINUE_ID] = article.id;
    wantParam[CONTINUE_URL] = url;
    wantParam[CONTINUE_RATIO] = Number.isFinite(article.progressRatio)
      ? Math.max(0, Math.min(1, article.progressRatio)) : 0;
    return AbilityConstant.OnContinueResult.AGREE;
  }

  accept(want: Want, launchParam: AbilityConstant.LaunchParam): boolean {
    if (launchParam.launchReason !== AbilityConstant.LaunchReason.CONTINUATION) {
      return false;
    }
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined || params[CONTINUE_VERSION] !== 1) {
      return false;
    }
    const articleId: Object | undefined = params[CONTINUE_ID];
    const url: Object | undefined = params[CONTINUE_URL];
    const ratio: Object | undefined = params[CONTINUE_RATIO];
    if (typeof articleId !== 'string' || typeof url !== 'string' || typeof ratio !== 'number') {
      return false;
    }
    const safeUrl: string = normalizeWebPageUrl(url);
    if (safeUrl.length === 0 || !Number.isFinite(ratio) || ratio < 0 || ratio > 1) {
      return false;
    }
    this.pending = new ContinueRequest(articleId, safeUrl, ratio);
    return true;
  }

  take(): ContinueRequest | undefined {
    const request: ContinueRequest | undefined = this.pending;
    this.pending = undefined;
    return request;
  }
}

export const readingContinuation: ReadingContinuation = new ReadingContinuation();
