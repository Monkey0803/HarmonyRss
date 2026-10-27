/*
 * LocaleController.ets — 语言（跟随系统 / 简体中文 / 繁體中文 / 日 / 德 / 法 / 西 / 英语）。
 *
 * `setAppPreferredLanguage('default')` = 跟随系统。但需求要求：当系统语言没有对应资源时，
 * 默认使用英语 —— 所以「跟随系统」在这种系统语言下改成显式 'en'。
 */

import { i18n } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLanguage } from '../common/constants/SettingsConstants';

/** 有本地化资源的语言（base 为英语，其余语言目录按语言码命名）。 */
const SUPPORTED_LANGUAGES: string[] = ['zh', 'en', 'ja', 'de', 'fr', 'es'];

/** 应用语言 id → 系统语言标签。 */
function tagOf(mode: string): string {
  if (mode === AppLanguage.ZH) {
    return 'zh-Hans';
  }
  if (mode === AppLanguage.ZH_TW) {
    return 'zh-Hant';
  }
  return mode;
}

/** 系统语言是否已有本地化资源（取语言主标签比较，忽略地区）。 */
function supported(systemLanguage: string): boolean {
  const lower: string = systemLanguage.toLowerCase();
  for (let i = 0; i < SUPPORTED_LANGUAGES.length; i += 1) {
    if (lower.indexOf(SUPPORTED_LANGUAGES[i]) === 0) {
      return true;
    }
  }
  return false;
}

export class LocaleController {
  static apply(mode: string): void {
    try {
      if (mode !== AppLanguage.SYSTEM) {
        i18n.System.setAppPreferredLanguage(tagOf(mode));
        return;
      }
      const systemLanguage: string = i18n.System.getSystemLanguage();
      if (supported(systemLanguage)) {
        i18n.System.setAppPreferredLanguage('default');
      } else {
        i18n.System.setAppPreferredLanguage('en');
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('LocaleController.apply failed: ' + error.code.toString());
    }
  }
}
