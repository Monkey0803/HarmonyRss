/*
 * TranslateConstants.ets — 正文翻译的默认值与硬上限。
 *
 * 隐私约束：联网翻译默认关闭；只有用户显式开启并配置服务后才外发正文。
 * API Key 不在这里，也不进 preferences —— 见 service/TranslateSecretStore.ets（Asset Store）。
 */

/** 第三方翻译服务。 */
export enum TranslateProvider {
  /** DeepL（默认；免费 Key 用 api-free，付费 key 可自定义 endpoint）。 */
  DEEPL = 'deepl',
  /** LibreTranslate 兼容接口（自建 / 公共实例）。 */
  LIBRE = 'libre'
}

export class TranslateDefaults {
  /** 联网翻译默认关闭（隐私优先）。 */
  static readonly ENABLED: boolean = false;
  static readonly PROVIDER: string = TranslateProvider.DEEPL;
  /** DeepL 免费版端点；付费 Key 需在设置页改成 https://api.deepl.com/v2/translate。 */
  static readonly DEEPL_ENDPOINT: string = 'https://api-free.deepl.com/v2/translate';
  static readonly LIBRE_ENDPOINT: string = 'https://libretranslate.com/translate';
}

export class TranslateLimits {
  /** 单篇文章参与翻译的最大字符数（超出部分不翻译，避免费用失控）。 */
  static readonly MAX_CHARS: number = 20000;
  /** 单篇最多段落数（其余截断）。 */
  static readonly MAX_PARAGRAPHS: number = 200;
  /** 单段超过该长度时按句号切分，保证逐段对照可读。 */
  static readonly PARAGRAPH_CHARS: number = 1200;
  /** 一次请求最多带几段（DeepL 支持多个 text 参数）。 */
  static readonly MAX_BATCH_PARAGRAPHS: number = 20;
  /** 单次请求的文本字符上限。 */
  static readonly MAX_BATCH_CHARS: number = 4000;
  /** 翻译缓存保留天数。 */
  static readonly CACHE_DAYS: number = 90;
  /** 翻译缓存最多保留条数（超出时清理最旧的）。 */
  static readonly MAX_CACHE_ENTRIES: number = 500;
}
