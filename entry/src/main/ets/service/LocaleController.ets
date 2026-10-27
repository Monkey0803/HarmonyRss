/*
 * LocaleController.ets — 语言（跟随系统 / 简体中文 / 繁體中文 / 英语）。
 *
 * `setAppPreferredLanguage('default')` = 跟随系统。但需求要求：当系统语言既不是英语也
 * 不是简体中文时，默认使用英语 —— 所以「跟随系统」在这种系统语言下改成显式 'en'。
 */

import { i18n } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLanguage } from '../common/constants/SettingsConstants';

export class LocaleController {
  static apply(mode: string): void {
    try {
      if (mode === AppLanguage.ZH) {
        i18n.System.setAppPreferredLanguage('zh-Hans');
        return;
      }
      if (mode === AppLanguage.ZH_TW) {
        i18n.System.setAppPreferredLanguage('zh-Hant');
        return;
      }
      if (mode === AppLanguage.EN) {
        i18n.System.setAppPreferredLanguage('en');
        return;
      }
      const systemLanguage: string = i18n.System.getSystemLanguage();
      if (systemLanguage.indexOf('zh') === 0 || systemLanguage.indexOf('en') === 0) {
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
