/*
 * TranslationPolicy.test.ets — 翻译纯逻辑单测。
 *
 * 覆盖：语言识别、目标语言跟随应用语言、同语言判定、段落切分 / 批量上限、
 * 服务端点归一（自定义 http/https 才生效）。
 * 不发网络请求、不打开数据库。
 */

import { describe, it, expect } from '@ohos/hypium';
import { TranslateDefaults, TranslateLimits } from '../../../main/ets/common/constants/TranslateConstants';
import { AppLanguage } from '../../../main/ets/common/constants/SettingsConstants';
import {
  aiCacheKey, aiEndpointOf, aiModelOf, buildAiTranslationRequest,
  isValidAiEndpoint, parseAiTranslationResponse
} from '../../../main/ets/service/AiTranslationProtocol';
import {
  chunkParagraphs,
  detectLanguage,
  isSameLanguage,
  needsTranslation,
  resolveTargetLanguage,
  splitParagraphs,
  targetLanguageOf,
  targetPromptName
} from '../../../main/ets/service/TranslationPolicy';

function completion(content: string, finish: string = 'stop'): string {
  return '{"choices":[{"finish_reason":"' + finish + '","message":{"content":' +
    JSON.stringify(content) + '}}]}';
}

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

    it('target_language_explicit_override', 0, () => {
      expect(resolveTargetLanguage('zh', AppLanguage.EN, 'en-US')).assertEqual('zh');
      expect(resolveTargetLanguage('zh-hant', AppLanguage.EN, 'en-US')).assertEqual('zh-hant');
      expect(resolveTargetLanguage('de', AppLanguage.ZH, 'zh-Hans')).assertEqual('de');
      expect(resolveTargetLanguage('auto', AppLanguage.JA, 'zh-Hans')).assertEqual('ja');
      expect(resolveTargetLanguage('ko', AppLanguage.EN, 'en-US')).assertEqual('en');
    });

    it('needs_translation_allows_simplified_to_traditional', 0, () => {
      expect(needsTranslation('zh', 'zh')).assertFalse();
      expect(needsTranslation('en', 'en')).assertFalse();
      expect(needsTranslation('zh', 'zh-hant')).assertTrue();
      expect(needsTranslation('en', 'zh')).assertTrue();
      expect(needsTranslation('und', 'zh')).assertTrue();
    });

    it('target_prompt_name_is_readable', 0, () => {
      expect(targetPromptName('zh')).assertEqual('Simplified Chinese');
      expect(targetPromptName('zh-hant')).assertEqual('Traditional Chinese');
      expect(targetPromptName('de')).assertEqual('German');
    });

    it('split_paragraphs_skips_blank_lines', 0, () => {
      const result: string[] = splitParagraphs('第一段\n\n  \n第二段\n第三段');
      expect(result.length).assertEqual(3);
      expect(result[0]).assertEqual('第一段');
      expect(result[1]).assertEqual('第二段');
      expect(result[2]).assertEqual('第三段');
    });

    it('split_paragraphs_joins_web_fragmented_sentences', 0, () => {
      const text: string = 'You might know of some rule in your jurisdiction which overrides local\n' +
        'rules, and allows certain classes of vehicles.\nPlease disregard these\n' +
        'rules; the park isn\'t necessarily in your jurisdiction.\nOr perhaps\n' +
        'your religion allows certain rules to be overridden.';
      const result: string[] = splitParagraphs(text);
      expect(result.length).assertEqual(3);
      expect(result[0]).assertEqual('You might know of some rule in your jurisdiction which overrides local ' +
        'rules, and allows certain classes of vehicles.');
      expect(result[1]).assertEqual('Please disregard these rules; the park isn\'t necessarily in your jurisdiction.');
      expect(result[2]).assertEqual('Or perhaps your religion allows certain rules to be overridden.');
    });

    it('split_paragraphs_keeps_explicit_break_and_title', 0, () => {
      const result: string[] = splitParagraphs('No Vehicles in the Park\nThis is a game about rules.\n' +
        'A sentence without a period\n\nNext paragraph starts here.');
      expect(result.length).assertEqual(4);
      expect(result[0]).assertEqual('No Vehicles in the Park');
      expect(result[2]).assertEqual('A sentence without a period');
      expect(result[3]).assertEqual('Next paragraph starts here.');
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

    it('ai_configuration_and_cache_isolation', 0, () => {
      expect(aiEndpointOf('')).assertEqual(TranslateDefaults.AI_ENDPOINT);
      expect(aiModelOf('')).assertEqual(TranslateDefaults.AI_MODEL);
      expect(isValidAiEndpoint('https://example.com/v1/chat/completions')).assertTrue();
      expect(isValidAiEndpoint('http://example.com/v1/chat/completions')).assertFalse();
      expect(isValidAiEndpoint('https://user:pass@example.com/v1/chat/completions')).assertFalse();
      expect(aiCacheKey('article', 'zh', 'https://a.example/v1/chat/completions', 'model-a') ===
        aiCacheKey('article', 'zh', 'https://a.example/v1/chat/completions', 'model-b')).assertFalse();
      expect(aiCacheKey('article', 'zh', 'https://a.example/v1/chat/completions', 'model-a') ===
        aiCacheKey('article', 'zh', 'https://b.example/v1/chat/completions', 'model-a')).assertFalse();
      expect(aiCacheKey('article', 'zh', '', '').startsWith('["v2",')).assertTrue();
    });

    it('ai_request_numbers_each_batch', 0, () => {
      const batches: string[][] = chunkParagraphs(['one', 'two', 'three'], 2, 4000);
      const first: string = buildAiTranslationRequest(batches[0], 'zh', 'model-a');
      const second: string = buildAiTranslationRequest(batches[1], 'zh', 'model-a');
      expect(first.indexOf('\\"index\\":0') >= 0).assertTrue();
      expect(first.indexOf('\\"index\\":1') >= 0).assertTrue();
      expect(second.indexOf('\\"index\\":0') >= 0).assertTrue();
      expect(first.indexOf('model-a') >= 0).assertTrue();
    });

    it('ai_response_rejects_missing_misordered_or_empty_paragraphs', 0, () => {
      const valid: string = completion('{"translations":[{"index":0,"text":"甲"},{"index":1,"text":"乙"}]}');
      expect(parseAiTranslationResponse(valid, 2)[1]).assertEqual('乙');
      const invalid: string[] = [
        completion('{"translations":[{"index":1,"text":"错位"}]}'),
        completion('{"translations":[{"index":0,"text":" "}]}'),
        completion('{"translations":[{"index":0,"text":"未完成"}]}', 'length')
      ];
      for (let i = 0; i < invalid.length; i += 1) {
        let rejected: boolean = false;
        try { parseAiTranslationResponse(invalid[i], 1); } catch (err) { rejected = true; }
        expect(rejected).assertTrue();
      }
    });
  });
}
