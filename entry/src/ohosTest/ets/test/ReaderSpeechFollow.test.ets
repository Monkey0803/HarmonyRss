import { describe, it, expect } from '@ohos/hypium';
import { speechLanguageOf, SPEECH_CHINESE, SPEECH_ENGLISH } from '../../../main/ets/service/ReaderSpeechLanguage';
import { parseSpeechSegments, markSpeechSegmentScript } from '../../../main/ets/service/ReaderSpeechDocument';

export default function readerSpeechFollowTest() {
  describe('ReaderSpeechFollow', () => {
    it('selects_chinese_and_english_without_falling_back_to_wrong_voice', 0, () => {
      expect(speechLanguageOf('这是一篇关于阅读体验的文章，我们会逐段朗读正文内容。')).assertEqual(SPEECH_CHINESE);
      expect(speechLanguageOf('This article explains how the reader follows the spoken paragraph and keeps your place.'))
        .assertEqual(SPEECH_ENGLISH);
      expect(speechLanguageOf('これは日本語の記事です。読み上げを試します。')).assertEqual('');
      expect(speechLanguageOf('Ceci est un article français sur la lecture à voix haute.')).assertEqual('');
    });

    it('parses_arkweb_encoded_segments_and_rejects_bad_rows', 0, () => {
      const json: string = '[{"id":0,"text":" First paragraph "},{"id":1,"text":"Second paragraph"},' +
        '{"id":-1,"text":"bad"},{"id":2,"text":"  "}]';
      const segments = parseSpeechSegments(JSON.stringify(json));
      expect(segments.length).assertEqual(2);
      expect(segments[0].id).assertEqual(0);
      expect(segments[0].text).assertEqual('First paragraph');
      expect(segments[1].id).assertEqual(1);
      expect(parseSpeechSegments('broken').length).assertEqual(0);
    });

    it('only_scrolls_when_follow_is_enabled', 0, () => {
      expect(markSpeechSegmentScript(2, true).includes('scrollIntoView')).assertTrue();
      expect(markSpeechSegmentScript(2, false).includes('scrollIntoView')).assertFalse();
    });
  });
}
