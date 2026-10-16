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
    it('font_size_levels', 0, () => {
      expect(ReaderTypography.fontSize(ReaderFontSize.SMALL)).assertEqual(15);
      expect(ReaderTypography.fontSize(ReaderFontSize.MEDIUM)).assertEqual(17);
      expect(ReaderTypography.fontSize(ReaderFontSize.LARGE)).assertEqual(20);
      expect(ReaderTypography.fontSize('unknown')).assertEqual(17);
    });

    it('line_height_levels', 0, () => {
      expect(ReaderTypography.lineHeight(ReaderLineHeight.COMPACT)).assertEqual(1.4);
      expect(ReaderTypography.lineHeight(ReaderLineHeight.NORMAL)).assertEqual(1.7);
      expect(ReaderTypography.lineHeight(ReaderLineHeight.LOOSE)).assertEqual(2.0);
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
