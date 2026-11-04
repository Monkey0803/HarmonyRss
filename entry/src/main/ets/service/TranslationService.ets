/*
 * TranslationService.ets — OpenAI 兼容 AI 正文翻译编排。
 *
 * 约束：
 *   - 联网翻译默认关闭，只有 appSettings.translateEnabled = true 才发起请求；
 *   - API Key 只从 Asset Store 读，不进 preferences / 日志；
 *   - 结果按文章、目标语言、端点和模型缓存到独立 RDB，重复打开不再计费；
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
import { TranslateLimits } from '../common/constants/TranslateConstants';
import { HttpError, HttpMethod, HttpOptions, HttpResponse, httpClient } from './HttpClient';
import {
  chunkParagraphs,
  detectLanguage,
  isSameLanguage,
  splitParagraphs,
  targetLanguageOf
} from './TranslationPolicy';
import { translationStore } from './TranslationStore';
import { aiTranslateSecretStore } from './TranslateSecretStore';
import {
  aiCacheKey, aiEndpointOf, aiModelOf, buildAiTranslationRequest,
  isValidAiEndpoint, parseAiTranslationResponse
} from './AiTranslationProtocol';

const DOMAIN: number = 0x0000;
const TAG: string = 'TranslationService';

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
    return isValidAiEndpoint(appSettings.translateAiEndpoint) &&
      aiModelOf(appSettings.translateAiModel).length > 0 && await aiTranslateSecretStore.hasKey();
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
    const endpoint: string = aiEndpointOf(appSettings.translateAiEndpoint);
    const model: string = aiModelOf(appSettings.translateAiModel);
    const cacheKey: string = aiCacheKey(articleId, target, endpoint, model);
    await translationStore.open(context);
    if (!force) {
      const cached = await translationStore.getAi(cacheKey);
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
    const translated: string[] = await this.translateParagraphs(paragraphs, target, endpoint, model);
    const resultParagraphs: TranslationParagraph[] = [];
    for (let i = 0; i < paragraphs.length; i += 1) {
      const value: string = i < translated.length ? translated[i] : '';
      resultParagraphs.push(new TranslationParagraph(paragraphs[i], value));
    }
    const truncated: boolean = paragraphs.join('').replace(/\s+/g, '').length < raw.replace(/\s+/g, '').length;
    translationStore.putAi(cacheKey, articleId, source, target, this.encodePayload(resultParagraphs));
    return new TranslationResult(resultParagraphs, source, target, 'ai', false, truncated);
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
    const translated: string[] = await this.translateParagraphs(paragraphs, target,
      aiEndpointOf(appSettings.translateAiEndpoint), aiModelOf(appSettings.translateAiModel));
    return translated.join('\n\n');
  }

  /** 设置页「测试翻译」：翻译一句固定文本并返回结果。 */
  async test(context: common.Context): Promise<string> {
    const target: string = this.targetLanguage();
    // 目标中文时用英文样本，目标英文时用中文样本：避免「同语言翻译」造成误报。
    const sample: string = target === 'zh' ? 'Hello, world!' : '你好，世界！';
    const translated: string[] = await this.translateParagraphs([sample], target,
      aiEndpointOf(appSettings.translateAiEndpoint), aiModelOf(appSettings.translateAiModel));
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
    endpoint: string, model: string): Promise<string[]> {
    if (!isValidAiEndpoint(endpoint) || model.length === 0) {
      throw new TranslationError(TranslationErrorCode.NOT_CONFIGURED, 'invalid AI configuration');
    }
    const key: string | undefined = await aiTranslateSecretStore.read();
    if (key === undefined || key.length === 0) {
      throw new TranslationError(TranslationErrorCode.NOT_CONFIGURED, 'missing AI api key');
    }
    const batches: string[][] = chunkParagraphs(paragraphs);
    const result: string[] = [];
    for (let i = 0; i < batches.length; i += 1) {
      const batch: string[] = batches[i];
      const translated: string[] = await this.translateAi(batch, target, endpoint, model, key);
      if (translated.length !== batch.length) {
        throw new TranslationError(TranslationErrorCode.PARSE, 'translation count mismatch');
      }
      for (let j = 0; j < translated.length; j += 1) {
        result.push(translated[j]);
      }
    }
    return result;
  }

  private async translateAi(texts: string[], target: string, endpoint: string,
    model: string, key: string): Promise<string[]> {
    const response: HttpResponse = await this.post(endpoint,
      buildAiTranslationRequest(texts, target, model), key);
    this.ensureOk(response, 'ai');
    return parseAiTranslationResponse(response.text, texts.length);
  }

  /** 统一 POST（避免两处重复拼请求头 / body）。 */
  private async post(url: string, body: string, key: string): Promise<HttpResponse> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer ' + key
    };
    const options: HttpOptions = new HttpOptions();
    options.headers = headers;
    options.body = body;
    // A timed-out completion may still be billed; never send the same batch again automatically.
    options.maxRetries = 0;
    options.readTimeoutMs = 60000;
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
    if (response.status === 400 || response.status === 404 || response.status === 422) {
      throw new TranslationError(TranslationErrorCode.MODEL, 'HTTP ' + response.status.toString());
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
