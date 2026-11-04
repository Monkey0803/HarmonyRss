/*
 * TranslateConstants.ets — 正文翻译的默认值与硬上限。
 *
 * 隐私约束：联网翻译默认关闭；只有用户显式开启并配置服务后才外发正文。
 * API Key 不在这里，也不进 preferences —— 见 service/TranslateSecretStore.ets（Asset Store）。
 */

export class TranslateDefaults {
  /** 联网翻译默认关闭（隐私优先）。 */
  static readonly ENABLED: boolean = false;
  static readonly AI_ENDPOINT: string = 'https://api.openai.com/v1/chat/completions';
  static readonly AI_MODEL: string = 'gpt-4.1-mini';
  /** 目标语言默认值：跟随应用语言（保持历史行为）。 */
  static readonly AI_TARGET_LANG: string = 'auto';
}

export class TranslateLimits {
  /** 单篇文章参与翻译的最大字符数（超出部分不翻译，避免费用失控）。 */
  static readonly MAX_CHARS: number = 20000;
  /** 单篇最多段落数（其余截断）。 */
  static readonly MAX_PARAGRAPHS: number = 200;
  /** 单段超过该长度时按句号切分，保证逐段对照可读。 */
  static readonly PARAGRAPH_CHARS: number = 1200;
  /** 一次请求最多带几段。 */
  static readonly MAX_BATCH_PARAGRAPHS: number = 20;
  /** 单次请求的文本字符上限。 */
  static readonly MAX_BATCH_CHARS: number = 4000;
  /** 翻译缓存保留天数。 */
  static readonly CACHE_DAYS: number = 90;
  /** 翻译缓存最多保留条数（超出时清理最旧的）。 */
  static readonly MAX_CACHE_ENTRIES: number = 500;
}
