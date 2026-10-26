/*
 * TranslationText.ets — 翻译错误 / 语言代码 → 界面文案。
 *
 * 两个页面（设置页、阅读页翻译面板）共用，避免中英文案各写一份漂移。
 */

import { TranslationErrorCode } from '../../model/Translation';

/** 错误码 → 可操作提示。 */
export function translationErrorText(code: string): ResourceStr {
  if (code === TranslationErrorCode.DISABLED) {
    return $r('app.string.translate_error_disabled_title');
  }
  if (code === TranslationErrorCode.NOT_CONFIGURED) {
    return $r('app.string.translate_error_not_configured');
  }
  if (code === TranslationErrorCode.EMPTY) {
    return $r('app.string.translate_error_empty');
  }
  if (code === TranslationErrorCode.SAME_LANGUAGE) {
    return $r('app.string.translate_error_same');
  }
  if (code === TranslationErrorCode.AUTH) {
    return $r('app.string.translate_error_auth');
  }
  if (code === TranslationErrorCode.RATE_LIMIT) {
    return $r('app.string.translate_error_rate');
  }
  if (code === TranslationErrorCode.SERVER) {
    return $r('app.string.translate_error_server');
  }
  if (code === TranslationErrorCode.PARSE) {
    return $r('app.string.translate_error_parse');
  }
  return $r('app.string.translate_error_network');
}

/** 语言代码 → 本地化名称。 */
export function languageText(code: string): ResourceStr {
  if (code === 'zh') {
    return $r('app.string.translate_lang_zh');
  }
  if (code === 'ja') {
    return $r('app.string.translate_lang_ja');
  }
  if (code === 'ko') {
    return $r('app.string.translate_lang_ko');
  }
  if (code === 'ru') {
    return $r('app.string.translate_lang_ru');
  }
  if (code === 'ar') {
    return $r('app.string.translate_lang_ar');
  }
  if (code === 'und') {
    return $r('app.string.translate_lang_und');
  }
  return $r('app.string.translate_lang_en');
}
