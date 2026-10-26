/*
 * TranslationViewModel.ets — 翻译面板 / 设置页的状态（@ObservedV2）。
 *
 * 视图只读状态与调用动作；网络 / 缓存 / Key 都在 TranslationService。
 * 打开面板时若有缓存立即展示，否则发起一次整篇翻译（用户点「翻译」本身就是显式动作）。
 */

import { common } from '@kit.AbilityKit';
import {
  TranslationError,
  TranslationErrorCode,
  TranslationParagraph,
  TranslationResult
} from '../model/Translation';
import { translationService } from '../service/TranslationService';

/** 面板状态。 */
const STATUS_IDLE: string = 'idle';
const STATUS_LOADING: string = 'loading';
const STATUS_READY: string = 'ready';
const STATUS_ERROR: string = 'error';

@ObservedV2
export class TranslationViewModel {
  /** 面板整体状态：idle / loading / ready / error。 */
  @Trace status: string = STATUS_IDLE;
  /** 错误分类（TranslationErrorCode 的字符串值）；空串 = 无错误。 */
  @Trace errorCode: string = '';
  /** 逐段对照结果。 */
  @Trace paragraphs: TranslationParagraph[] = [];
  @Trace sourceLang: string = '';
  @Trace targetLang: string = '';
  @Trace provider: string = '';
  @Trace fromCache: boolean = false;
  /** 正文过长被截断（只翻译了前 N 字）。 */
  @Trace truncated: boolean = false;
  /** 只看译文（隐藏原文）。 */
  @Trace onlyTranslation: boolean = false;

  /** 选中文本翻译：原文 / 译文 / 状态 / 错误。 */
  @Trace selectionOriginal: string = '';
  @Trace selectionTranslated: string = '';
  @Trace selectionStatus: string = STATUS_IDLE;
  @Trace selectionError: string = '';

  /** 当前文章与纯文本（重新翻译时复用）。 */
  private articleId: string = '';
  private sourceText: string = '';
  private context: common.Context | undefined = undefined;

  /** 打开某篇文章的翻译面板；有缓存先展示，否则直接翻译。 */
  async openArticle(context: common.Context, articleId: string, text: string): Promise<void> {
    this.context = context;
    this.articleId = articleId;
    this.sourceText = text;
    this.paragraphs = [];
    this.sourceLang = '';
    this.targetLang = translationService.targetLanguage();
    this.provider = '';
    this.fromCache = false;
    this.truncated = false;
    this.errorCode = '';
    this.status = STATUS_LOADING;
    await this.run(false);
  }

  /** 重新翻译（忽略缓存）。 */
  async retry(): Promise<void> {
    if (this.context === undefined || this.articleId.length === 0) {
      return;
    }
    this.status = STATUS_LOADING;
    this.errorCode = '';
    await this.run(true);
  }

  /** 翻译选中文本（不写文章缓存）。 */
  async translateSelection(context: common.Context, text: string): Promise<void> {
    this.context = context;
    // 选段翻译独立展示：清掉上一篇的整篇结果，避免面板里出现无关段落。
    this.paragraphs = [];
    this.sourceLang = '';
    this.provider = '';
    this.fromCache = false;
    this.truncated = false;
    this.errorCode = '';
    this.status = STATUS_IDLE;
    this.articleId = '';
    this.sourceText = '';
    this.selectionOriginal = text.trim();
    this.selectionTranslated = '';
    this.selectionError = '';
    this.selectionStatus = STATUS_LOADING;
    try {
      const translated: string = await translationService.translateSelection(context, text);
      this.selectionTranslated = translated;
      this.selectionStatus = STATUS_READY;
    } catch (err) {
      this.selectionError = this.codeOf(err);
      this.selectionStatus = STATUS_ERROR;
    }
  }

  /** 清空选中文本结果。 */
  clearSelection(): void {
    this.selectionOriginal = '';
    this.selectionTranslated = '';
    this.selectionError = '';
    this.selectionStatus = STATUS_IDLE;
  }

  /** 关闭面板：保留文章结果（下次打开命中缓存），清掉选段结果。 */
  close(): void {
    this.clearSelection();
    this.onlyTranslation = false;
  }

  private async run(force: boolean): Promise<void> {
    const context: common.Context | undefined = this.context;
    if (context === undefined) {
      this.status = STATUS_ERROR;
      this.errorCode = TranslationErrorCode.NETWORK;
      return;
    }
    try {
      const result: TranslationResult = await translationService.translateArticle(
        context, this.articleId, this.sourceText, force);
      this.paragraphs = result.paragraphs;
      this.sourceLang = result.sourceLang;
      this.targetLang = result.targetLang;
      this.provider = result.provider;
      this.fromCache = result.fromCache;
      this.truncated = result.truncated;
      this.status = STATUS_READY;
      this.errorCode = '';
    } catch (err) {
      this.errorCode = this.codeOf(err);
      this.status = STATUS_ERROR;
    }
  }

  /** 异常 → 错误码字符串（未知按网络错误处理）。 */
  private codeOf(err: Object): string {
    if (err instanceof TranslationError) {
      return err.code;
    }
    return TranslationErrorCode.NETWORK;
  }
}

/** 全局唯一 ViewModel。 */
export const translationViewModel: TranslationViewModel = new TranslationViewModel();
