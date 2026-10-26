/*
 * Translation.ets — 正文翻译的领域模型。
 *
 * 只有「段落 + 译文」是渲染需要的；语言与来源信息用于标题与缓存校验。
 * 错误统一走 TranslationError（code 便于界面映射成中英文案）。
 */

/** 一段原文与它的译文（逐段对照）。 */
export class TranslationParagraph {
  readonly original: string;
  readonly translated: string;

  constructor(original: string, translated: string) {
    this.original = original;
    this.translated = translated;
  }
}

/** 一次整篇翻译的结果。 */
export class TranslationResult {
  readonly paragraphs: TranslationParagraph[];
  readonly sourceLang: string;
  readonly targetLang: string;
  readonly provider: string;
  readonly fromCache: boolean;
  readonly truncated: boolean;

  constructor(paragraphs: TranslationParagraph[], sourceLang: string, targetLang: string,
    provider: string, fromCache: boolean, truncated: boolean) {
    this.paragraphs = paragraphs;
    this.sourceLang = sourceLang;
    this.targetLang = targetLang;
    this.provider = provider;
    this.fromCache = fromCache;
    this.truncated = truncated;
  }
}

/** 翻译失败分类（界面据此给可操作的提示）。 */
export enum TranslationErrorCode {
  /** 用户未开启联网翻译。 */
  DISABLED = 'disabled',
  /** 服务未配置完整（缺 Key / 端点非法）。 */
  NOT_CONFIGURED = 'notConfigured',
  /** 正文为空 / 没有可翻译段落。 */
  EMPTY = 'empty',
  /** 文章已经是目标语言。 */
  SAME_LANGUAGE = 'sameLanguage',
  /** 网络不可达 / 超时。 */
  NETWORK = 'network',
  /** 401 / 403：Key 无效。 */
  AUTH = 'auth',
  /** 429：被限流。 */
  RATE_LIMIT = 'rateLimit',
  /** 5xx：服务端错误。 */
  SERVER = 'server',
  /** 响应无法解析。 */
  PARSE = 'parse'
}

/** 翻译异常。 */
export class TranslationError extends Error {
  readonly code: TranslationErrorCode;

  constructor(code: TranslationErrorCode, message: string) {
    super(message);
    this.code = code;
  }
}
