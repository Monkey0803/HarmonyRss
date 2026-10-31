/* Core Speech Kit 离线语音目前只支持中文与英文；用正文样本保守选择。 */

export const SPEECH_CHINESE: string = 'zh-CN';
export const SPEECH_ENGLISH: string = 'en-US';

/** 返回空串表示无法可靠映射到本机支持的语音。 */
export function speechLanguageOf(text: string): string {
  const sample: string = text.substring(0, 4000).toLowerCase();
  const kana: number = (sample.match(/[\u3040-\u30ff]/g) ?? []).length;
  const hangul: number = (sample.match(/[\uac00-\ud7af]/g) ?? []).length;
  if (kana > 2 || hangul > 2 || /[\u0400-\u04ff\u0370-\u03ff]/.test(sample)) {
    return '';
  }
  const han: number = (sample.match(/[\u3400-\u9fff]/g) ?? []).length;
  const latin: number = (sample.match(/[a-z]/g) ?? []).length;
  if (han >= 8 && han >= latin / 3) {
    return SPEECH_CHINESE;
  }
  if (latin < 24 || /[à-öø-ÿ]/.test(sample)) {
    return '';
  }
  const common: RegExp = /\b(the|and|that|with|from|this|have|will|your|about|into|which|their|there|when|what|where|would|could|should)\b/g;
  const matches: RegExpMatchArray | null = sample.match(common);
  return matches !== null && matches.length >= 2 ? SPEECH_ENGLISH : '';
}
