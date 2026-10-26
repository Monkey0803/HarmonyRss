/*
 * TranslationService.ets — 正文翻译编排（系统能力不可用 → 第三方服务）。
 *
 * 当前 HarmonyOS SDK 没有可用的系统级文本翻译 API，所以 runtime 走「可配置的第三方服务」：
 *   - DeepL：POST 表单，支持一次多个 text（逐段对照）；
 *   - LibreTranslate 兼容：POST JSON，q 支持字符串 / 字符串数组。
 *
 * 约束：
 *   - 联网翻译默认关闭，只有 appSettings.translateEnabled = true 才发起请求；
 *   - API Key 只从 Asset Store 读，不进 preferences / 日志；
 *   - 结果按 (articleId, targetLang) 缓存到独立 RDB，重复打开不再计费；
 *   - 任何失败都转成 TranslationError，由界面给可操作提示，不影响阅读。
 */

import { common } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appSettings } from '../model/AppSettings';
import {
  TranslationError,
  TranslationErrorCode,
  TranslationParagraph,
  TranslationResult
} from '../model/Translation';
import { TranslateLimits, TranslateProvider } from '../common/constants/TranslateConstants';
import { HttpError, HttpMethod, HttpOptions, HttpResponse, httpClient } from './HttpClient';
import {
  chunkParagraphs,
  deepLTarget,
  detectLanguage,
  endpointOf,
  isSameLanguage,
  normalizeProvider,
  splitParagraphs,
  targetLanguageOf
} from './TranslationPolicy';
import { translationStore } from './TranslationStore';
import { translateSecretStore } from './TranslateSecretStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'TranslationService';

/** DeepL 响应（只取需要的字段）。 */
interface DeepLTranslationItem {
  text?: string;
}

interface DeepLResponse {
  translations?: DeepLTranslationItem[];
  message?: string;
}

/** LibreTranslate 响应：translatedText 可能是字符串或字符串数组。 */
interface LibreResponse {
  translatedText?: string | string[];
  error?: string;
}

/** LibreTranslate 请求体（q 传数组表示批量）。 */
interface LibreRequest {
  q: string[];
  source: string;
  target: string;
  format: string;
  api_key?: string;
}

/** 缓存里的一段（payload JSON 的扁平结构）。 */
interface CachedParagraph {
  o?: string;
  t?: string;
}

/** 截断错误正文，避免把服务端返回整页 HTML 打进日志 / 界面。 */
function shortMessage(text: string): string {
  const flat: string = text.replace(/\s+/g, ' ').trim();
  return flat.length > 200 ? flat.substring(0, 200) : flat;
}

/** 表单参数编码。 */
function formEncode(pairs: string[]): string {
  return pairs.join('&');
}

export class TranslationService {
  /** 应用语言 → 目标语言（跟随系统时按系统语言决定中/英）。 */
  targetLanguage(): string {
    let system: string = 'en';
    try {
      system = i18n.System.getSystemLanguage();
    } catch (err) {
      system = 'en';
    }
    return targetLanguageOf(appSettings.languageMode, system);
  }

  /** 是否已具备发起翻译的条件（开关 + 服务配置）。 */
  async isConfigured(): Promise<boolean> {
    if (!appSettings.translateEnabled) {
      return false;
    }
    const provider: string = normalizeProvider(appSettings.translateProvider);
    if (provider === TranslateProvider.DEEPL) {
      return await translateSecretStore.hasKey();
    }
    // LibreTranslate 自建实例可以不配 Key；公共实例需要时在请求阶段报 AUTH。
    return true;
  }

  /**
   * 整篇翻译。
   * @param force true 时忽略缓存重新请求（用户点「重新翻译」）。
   */
  async translateArticle(context: common.Context, articleId: string, text: string,
    force: boolean = false): Promise<TranslationResult> {
    if (!appSettings.translateEnabled) {
      throw new TranslationError(TranslationErrorCode.DISABLED, 'translation disabled');
    }
    const raw: string = text.trim();
    if (raw.length === 0) {
      throw new TranslationError(TranslationErrorCode.EMPTY, 'empty article text');
    }
    const target: string = this.targetLanguage();
    const source: string = detectLanguage(raw);
    if (isSameLanguage(source, target)) {
      throw new TranslationError(TranslationErrorCode.SAME_LANGUAGE, 'already target language');
    }
    await translationStore.open(context);
    if (!force) {
      const cached = await translationStore.get(articleId, target);
      if (cached !== undefined) {
        const parsed: TranslationParagraph[] = this.decodePayload(cached.payload);
        if (parsed.length > 0) {
          return new TranslationResult(parsed, cached.sourceLang, cached.targetLang,
            cached.provider, true, false);
        }
      }
    }
    const paragraphs: string[] = splitParagraphs(raw);
    if (paragraphs.length === 0) {
      throw new TranslationError(TranslationErrorCode.EMPTY, 'no translatable paragraph');
    }
    const provider: string = normalizeProvider(appSettings.translateProvider);
    const translated: string[] = await this.translateParagraphs(paragraphs, target, provider);
    const resultParagraphs: TranslationParagraph[] = [];
    let translatedChars: number = 0;
    for (let i = 0; i < paragraphs.length; i += 1) {
      const value: string = i < translated.length ? translated[i] : '';
      resultParagraphs.push(new TranslationParagraph(paragraphs[i], value));
      translatedChars += paragraphs[i].length;
    }
    const truncated: boolean = translatedChars < raw.length;
    translationStore.put(articleId, source, target, provider, this.encodePayload(resultParagraphs));
    return new TranslationResult(resultParagraphs, source, target, provider, false, truncated);
  }

  /** 翻译选中文本（不写文章缓存，返回单段字符串）。 */
  async translateSelection(context: common.Context, text: string): Promise<string> {
    if (!appSettings.translateEnabled) {
      throw new TranslationError(TranslationErrorCode.DISABLED, 'translation disabled');
    }
    const raw: string = text.trim();
    if (raw.length === 0) {
      throw new TranslationError(TranslationErrorCode.EMPTY, 'empty selection');
    }
    const target: string = this.targetLanguage();
    const source: string = detectLanguage(raw);
    if (isSameLanguage(source, target)) {
      throw new TranslationError(TranslationErrorCode.SAME_LANGUAGE, 'already target language');
    }
    const paragraphs: string[] = splitParagraphs(raw);
    const provider: string = normalizeProvider(appSettings.translateProvider);
    const translated: string[] = await this.translateParagraphs(paragraphs, target, provider);
    return translated.join('\n');
  }

  /** 设置页「测试翻译」：翻译一句固定文本并返回结果。 */
  async test(context: common.Context): Promise<string> {
    const target: string = this.targetLanguage();
    const provider: string = normalizeProvider(appSettings.translateProvider);
    // 目标中文时用英文样本，目标英文时用中文样本：避免「同语言翻译」造成误报。
    const sample: string = target === 'zh' ? 'Hello, world!' : '你好，世界！';
    const translated: string[] = await this.translateParagraphs([sample], target, provider);
    return translated.length > 0 ? translated[0] : '';
  }

  /** 缓存条数。 */
  async cacheCount(context: common.Context): Promise<number> {
    await translationStore.open(context);
    return await translationStore.count();
  }

  /** 清空缓存，返回清理条数。 */
  async clearCache(context: common.Context): Promise<number> {
    await translationStore.open(context);
    return await translationStore.clear();
  }

  /** 段落 → 批次 → 逐批请求（任何一批失败都整体失败，避免半篇译文）。 */
  private async translateParagraphs(paragraphs: string[], target: string,
    provider: string): Promise<string[]> {
    const endpoint: string = endpointOf(provider, appSettings.translateEndpoint);
    const key: string | undefined = await translateSecretStore.read();
    if (provider === TranslateProvider.DEEPL && (key === undefined || key.length === 0)) {
      throw new TranslationError(TranslationErrorCode.NOT_CONFIGURED, 'missing api key');
    }
    const batches: string[][] = chunkParagraphs(paragraphs);
    const result: string[] = [];
    for (let i = 0; i < batches.length; i += 1) {
      const batch: string[] = batches[i];
      let translated: string[];
      if (provider === TranslateProvider.LIBRE) {
        translated = await this.translateLibre(batch, target, endpoint, key);
      } else {
        translated = await this.translateDeepL(batch, target, endpoint, key ?? '');
      }
      if (translated.length !== batch.length) {
        throw new TranslationError(TranslationErrorCode.PARSE, 'translation count mismatch');
      }
      for (let j = 0; j < translated.length; j += 1) {
        result.push(translated[j]);
      }
    }
    return result;
  }

  /** DeepL：一次请求带多个 text，按返回顺序与输入段落一一对应（源语言交给服务自动检测）。 */
  private async translateDeepL(texts: string[], target: string,
    endpoint: string, key: string): Promise<string[]> {
    const pairs: string[] = [
      'auth_key=' + encodeURIComponent(key),
      'target_lang=' + deepLTarget(target),
      'preserve_formatting=1'
    ];
    for (let i = 0; i < texts.length; i += 1) {
      pairs.push('text=' + encodeURIComponent(texts[i]));
    }
    const body: string = formEncode(pairs);
    const response: HttpResponse =
      await this.post(endpoint, body, 'application/x-www-form-urlencoded');
    this.ensureOk(response, 'deepl');
    let parsed: DeepLResponse;
    try {
      parsed = JSON.parse(response.text) as DeepLResponse;
    } catch (err) {
      throw new TranslationError(TranslationErrorCode.PARSE, 'invalid deepl json');
    }
    const translations: DeepLTranslationItem[] | undefined = parsed.translations;
    if (translations === undefined || translations.length === 0) {
      throw new TranslationError(TranslationErrorCode.PARSE, shortMessage(response.text));
    }
    const result: string[] = [];
    for (let i = 0; i < translations.length; i += 1) {
      const text: string | undefined = translations[i].text;
      result.push(text !== undefined ? text : '');
    }
    return result;
  }

  /** LibreTranslate 兼容接口：q 传数组，translatedText 返回数组（source=auto）。 */
  private async translateLibre(texts: string[], target: string,
    endpoint: string, key: string | undefined): Promise<string[]> {
    const payload: LibreRequest = {
      q: texts,
      source: 'auto',
      target: target,
      format: 'text'
    };
    if (key !== undefined && key.length > 0) {
      payload.api_key = key;
    }
    const response: HttpResponse = await this.post(endpoint, JSON.stringify(payload), 'application/json');
    this.ensureOk(response, 'libre');
    let parsed: LibreResponse;
    try {
      parsed = JSON.parse(response.text) as LibreResponse;
    } catch (err) {
      throw new TranslationError(TranslationErrorCode.PARSE, 'invalid libre json');
    }
    const value: string | string[] | undefined = parsed.translatedText;
    if (value === undefined) {
      throw new TranslationError(TranslationErrorCode.PARSE, shortMessage(response.text));
    }
    if (typeof value === 'string') {
      return [value];
    }
    return value;
  }

  /** 统一 POST（避免两处重复拼请求头 / body）。 */
  private async post(url: string, body: string, contentType: string): Promise<HttpResponse> {
    const headers: Record<string, string> = {
      'Content-Type': contentType,
      'Accept': 'application/json'
    };
    const options: HttpOptions = new HttpOptions();
    options.headers = headers;
    options.body = body;
    options.maxRetries = 1;
    try {
      return await httpClient.request(HttpMethod.POST, url, options);
    } catch (err) {
      if (err instanceof HttpError) {
        throw new TranslationError(TranslationErrorCode.NETWORK, err.message);
      }
      const error: Error = err as Error;
      throw new TranslationError(TranslationErrorCode.NETWORK, error.message);
    }
  }

  /** 非 2xx → 分类错误。 */
  private ensureOk(response: HttpResponse, context: string): void {
    if (response.status >= 200 && response.status < 300) {
      return;
    }
    if (response.status === 401 || response.status === 403) {
      throw new TranslationError(TranslationErrorCode.AUTH, 'HTTP ' + response.status.toString());
    }
    if (response.status === 429) {
      throw new TranslationError(TranslationErrorCode.RATE_LIMIT, 'HTTP 429');
    }
    if (response.status >= 500) {
      throw new TranslationError(TranslationErrorCode.SERVER, 'HTTP ' + response.status.toString());
    }
    hilog.warn(DOMAIN, TAG, '%{public}s failed: HTTP %{public}d', context, response.status);
    throw new TranslationError(TranslationErrorCode.PARSE,
      'HTTP ' + response.status.toString() + ' ' + shortMessage(response.text));
  }

  /** 段落数组 → JSON（紧凑字段名减小缓存体积）。 */
  private encodePayload(paragraphs: TranslationParagraph[]): string {
    const records: CachedParagraph[] = [];
    for (let i = 0; i < paragraphs.length; i += 1) {
      records.push({ o: paragraphs[i].original, t: paragraphs[i].translated });
    }
    return JSON.stringify(records);
  }

  /** 缓存 JSON → 段落；损坏时返回空数组（调用方按未缓存处理）。 */
  private decodePayload(text: string): TranslationParagraph[] {
    if (text.length === 0) {
      return [];
    }
    try {
      const records: CachedParagraph[] = JSON.parse(text) as CachedParagraph[];
      const result: TranslationParagraph[] = [];
      for (let i = 0; i < records.length; i += 1) {
        const rawOriginal: string | undefined = records[i].o;
        const rawTranslated: string | undefined = records[i].t;
        const original: string = typeof rawOriginal === 'string' ? rawOriginal : '';
        const translated: string = typeof rawTranslated === 'string' ? rawTranslated : '';
        if (original.length > 0) {
          result.push(new TranslationParagraph(original, translated));
        }
      }
      return result;
    } catch (err) {
      return [];
    }
  }
}

/** 全局唯一实例。 */
export const translationService: TranslationService = new TranslationService();
