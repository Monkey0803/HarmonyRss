/*
 * TranslationPolicy.test.ets — 翻译纯逻辑单测。
 *
 * 覆盖：语言识别、目标语言跟随应用语言、同语言判定、段落切分 / 批量上限、
 * 服务端点归一（自定义 http/https 才生效）。
 * 不发网络请求、不打开数据库。
 */

import { describe, it, expect } from '@ohos/hypium';
import { TranslateDefaults, TranslateLimits, TranslateProvider } from '../../../main/ets/common/constants/TranslateConstants';
import { AppLanguage } from '../../../main/ets/common/constants/SettingsConstants';
import {
  chunkParagraphs,
  deepLSource,
  deepLTarget,
  detectLanguage,
  endpointOf,
  isSameLanguage,
  normalizeProvider,
  splitParagraphs,
  targetLanguageOf
} from '../../../main/ets/service/TranslationPolicy';

export default function translationPolicyTest() {
  describe('TranslationPolicy', () => {
    it('detect_language_by_script', 0, () => {
      expect(detectLanguage('Hello world, this is a test.')).assertEqual('en');
      expect(detectLanguage('这是一段中文正文，包含标点。')).assertEqual('zh');
      expect(detectLanguage('これは日本語のテストです。')).assertEqual('ja');
      expect(detectLanguage('안녕하세요 한국어 테스트입니다.')).assertEqual('ko');
      expect(detectLanguage('Это тест на русском языке.')).assertEqual('ru');
      expect(detectLanguage('مرحبا هذا اختبار باللغة العربية.')).assertEqual('ar');
      expect(detectLanguage('12345 !!!')).assertEqual('und');
    });

    it('target_language_follows_app_language', 0, () => {
      expect(targetLanguageOf(AppLanguage.ZH, 'en-US')).assertEqual('zh');
      expect(targetLanguageOf(AppLanguage.EN, 'zh-Hans')).assertEqual('en');
      expect(targetLanguageOf(AppLanguage.SYSTEM, 'zh-Hans')).assertEqual('zh');
      expect(targetLanguageOf(AppLanguage.SYSTEM, 'zh-Hant')).assertEqual('zh');
      expect(targetLanguageOf(AppLanguage.SYSTEM, 'ja-JP')).assertEqual('ja');
      expect(targetLanguageOf(AppLanguage.SYSTEM, 'de-AT')).assertEqual('de');
      expect(targetLanguageOf(AppLanguage.SYSTEM, 'fr-CA')).assertEqual('fr');
      expect(targetLanguageOf(AppLanguage.SYSTEM, 'es-MX')).assertEqual('es');
      expect(targetLanguageOf(AppLanguage.SYSTEM, 'ko-KR')).assertEqual('en');
      expect(targetLanguageOf(AppLanguage.JA, 'zh-Hans')).assertEqual('ja');
      expect(targetLanguageOf(AppLanguage.ZH_TW, 'en-US')).assertEqual('zh-hant');
      expect(targetLanguageOf(AppLanguage.SYSTEM, 'en-GB')).assertEqual('en');
    });

    it('same_language_check', 0, () => {
      expect(isSameLanguage('zh', 'zh')).assertTrue();
      expect(isSameLanguage('en', 'zh')).assertFalse();
      expect(isSameLanguage('und', 'zh')).assertFalse();
      expect(isSameLanguage('', 'zh')).assertFalse();
    });

    it('split_paragraphs_skips_blank_lines', 0, () => {
      const result: string[] = splitParagraphs('第一段\n\n  \n第二段\n第三段');
      expect(result.length).assertEqual(3);
      expect(result[0]).assertEqual('第一段');
      expect(result[1]).assertEqual('第二段');
      expect(result[2]).assertEqual('第三段');
    });

    it('split_paragraphs_cuts_long_lines', 0, () => {
      let line: string = '';
      for (let i = 0; i < 60; i += 1) {
        line += 'This is a sentence number ' + i.toString() + '. ';
      }
      const result: string[] = splitParagraphs(line);
      expect(result.length > 1).assertTrue();
      // 每段都不应超过单段上限。
      for (let i = 0; i < result.length; i += 1) {
        expect(result[i].length <= TranslateLimits.PARAGRAPH_CHARS).assertTrue();
      }
    });

    it('split_paragraphs_respects_total_limit', 0, () => {
      const result: string[] = splitParagraphs('a'.repeat(TranslateLimits.MAX_CHARS + 5000));
      let total: number = 0;
      for (let i = 0; i < result.length; i += 1) {
        total += result[i].length;
      }
      expect(total).assertEqual(TranslateLimits.MAX_CHARS);
      expect(result.length <= TranslateLimits.MAX_PARAGRAPHS).assertTrue();
    });

    it('chunk_paragraphs_by_count_and_chars', 0, () => {
      const paragraphs: string[] = [];
      for (let i = 0; i < 45; i += 1) {
        paragraphs.push('p' + i.toString());
      }
      const batches: string[][] = chunkParagraphs(paragraphs, 20, 4000);
      expect(batches.length).assertEqual(3);
      expect(batches[0].length).assertEqual(20);
      expect(batches[1].length).assertEqual(20);
      expect(batches[2].length).assertEqual(5);

      const long: string[] = ['a'.repeat(3000), 'b'.repeat(3000)];
      const byChars: string[][] = chunkParagraphs(long, 20, 4000);
      expect(byChars.length).assertEqual(2);
    });

    it('provider_and_endpoint_normalization', 0, () => {
      expect(normalizeProvider(TranslateProvider.LIBRE)).assertEqual(TranslateProvider.LIBRE);
      expect(normalizeProvider('unknown')).assertEqual(TranslateProvider.DEEPL);
      expect(endpointOf(TranslateProvider.DEEPL, '')).assertEqual(TranslateDefaults.DEEPL_ENDPOINT);
      expect(endpointOf(TranslateProvider.LIBRE, '')).assertEqual(TranslateDefaults.LIBRE_ENDPOINT);
      expect(endpointOf(TranslateProvider.DEEPL, 'https://example.com/translate'))
        .assertEqual('https://example.com/translate');
      // 非 http/https 的脏值退回默认端点。
      expect(endpointOf(TranslateProvider.DEEPL, 'ftp://example.com')).assertEqual(TranslateDefaults.DEEPL_ENDPOINT);
    });

    it('deepl_language_codes', 0, () => {
      expect(deepLTarget('zh')).assertEqual('ZH');
      expect(deepLTarget('en')).assertEqual('EN');
      expect(deepLSource('en')).assertEqual('EN');
      expect(deepLSource('und')).assertEqual('');
      expect(deepLSource('')).assertEqual('');
    });
  });
}
