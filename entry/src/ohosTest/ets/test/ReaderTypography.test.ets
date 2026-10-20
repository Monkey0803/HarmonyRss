/*
 * ReaderTypography.test.ets — 阅读排版档位映射与 Reader CSS 生成单测。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ReaderTypography,
  ReaderFontSize,
  ReaderLineHeight,
  ReaderFontFamily,
  ReaderWidth,
  ReaderAlign,
  ReaderTheme
} from '../../../main/ets/common/constants/SettingsConstants';
import { readerCss } from '../../../main/ets/service/ReaderDocument';
import { appSettings } from '../../../main/ets/model/AppSettings';

export default function readerTypographyTest() {
  describe('ReaderTypography', () => {
    it('font_size_scale', 0, () => {
      expect(ReaderTypography.fontSizePx(1)).assertEqual(17);
      // 超范围做收敛：下限 0.8、上限 1.6。
      expect(ReaderTypography.fontSizePx(0.5)).assertEqual(13.6);
      expect(ReaderTypography.fontSizePx(2)).assertEqual(27.2);
      expect(ReaderTypography.fontScaleOfPreset(ReaderFontSize.LARGE)).assertEqual(1.2);
    });

    it('line_height_scale', 0, () => {
      expect(ReaderTypography.lineHeightOf(1.7)).assertEqual(1.7);
      expect(ReaderTypography.lineHeightOf(0.1)).assertEqual(1.2);
      expect(ReaderTypography.lineHeightOf(5)).assertEqual(2.2);
    });

    it('font_family_css', 0, () => {
      expect(ReaderTypography.fontFamilyCss(ReaderFontFamily.SYSTEM)).assertEqual('');
      expect(ReaderTypography.fontFamilyCss(ReaderFontFamily.SERIF)).assertContain('Georgia');
      expect(ReaderTypography.fontFamilyCss(ReaderFontFamily.SANS)).assertContain('sans-serif');
    });

    it('content_width_levels', 0, () => {
      expect(ReaderTypography.contentWidthPx(ReaderWidth.NARROW)).assertEqual(560);
      expect(ReaderTypography.contentWidthPx(ReaderWidth.STANDARD)).assertEqual(720);
      expect(ReaderTypography.contentWidthPx(ReaderWidth.WIDE)).assertEqual(900);
    });

    it('align_css', 0, () => {
      expect(ReaderTypography.textAlignCss(ReaderAlign.LEFT)).assertEqual('left');
      expect(ReaderTypography.textAlignCss(ReaderAlign.JUSTIFY)).assertEqual('justify');
    });
  });

  describe('ReaderDocument', () => {
    it('css_reflects_typography_settings', 0, () => {
      const oldTheme: string = appSettings.readerTheme;
      const oldWidth: string = appSettings.readerWidth;
      const oldAlign: string = appSettings.readerAlign;
      const oldFamily: string = appSettings.readerFontFamily;

      appSettings.readerTheme = ReaderTheme.SEPIA;
      appSettings.readerWidth = ReaderWidth.WIDE;
      appSettings.readerAlign = ReaderAlign.JUSTIFY;
      appSettings.readerFontFamily = ReaderFontFamily.SERIF;
      const css: string = readerCss();
      expect(css).assertContain('#f6ecd9');
      expect(css).assertContain('max-width:900px');
      expect(css).assertContain('text-align:justify');
      expect(css).assertContain('Georgia');

      appSettings.readerTheme = oldTheme;
      appSettings.readerWidth = oldWidth;
      appSettings.readerAlign = oldAlign;
      appSettings.readerFontFamily = oldFamily;
    });

    it('system_theme_is_transparent_with_dark_override', 0, () => {
      const oldTheme: string = appSettings.readerTheme;
      appSettings.readerTheme = ReaderTheme.SYSTEM;
      const css: string = readerCss();
      expect(css).assertContain('background:transparent');
      expect(css).assertContain('prefers-color-scheme: dark');
      appSettings.readerTheme = oldTheme;
    });
  });
}
