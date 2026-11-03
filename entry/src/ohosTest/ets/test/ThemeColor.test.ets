/*
 * ThemeColor.test.ets — 主题色纯计算单测。
 *
 * 覆盖：颜色归一化、默认色不变、自定义色的可读性约束、tint 透明度、logo 派生色。
 */

import { describe, it, expect } from '@ohos/hypium';
import { ThemeColorMath, ThemeColorRoles } from '../../../main/ets/common/utils/ThemeColorMath';
import { DEFAULT_THEME_COLOR, LogoKind } from '../../../main/ets/common/constants/SettingsConstants';
import { logoStyleOf, LogoStyle } from '../../../main/ets/model/LogoStyles';

export default function themeColorTest() {
  describe('ThemeColorMath', () => {
    it('normalize_hex_forms', 0, () => {
      expect(ThemeColorMath.normalize('#abc', DEFAULT_THEME_COLOR)).assertEqual('#AABBCC');
      expect(ThemeColorMath.normalize('ff0000', DEFAULT_THEME_COLOR)).assertEqual('#FF0000');
      // HarmonyOS 常见 #AARRGGBB：忽略 alpha。
      expect(ThemeColorMath.normalize('#80FF0000', DEFAULT_THEME_COLOR)).assertEqual('#FF0000');
      expect(ThemeColorMath.normalize('rgb(255, 0, 0)', DEFAULT_THEME_COLOR)).assertEqual('#FF0000');
      expect(ThemeColorMath.normalize('rgba(0, 255, 0, 0.5)', DEFAULT_THEME_COLOR))
        .assertEqual('#00FF00');
      expect(ThemeColorMath.normalize('not-a-color', DEFAULT_THEME_COLOR))
        .assertEqual(DEFAULT_THEME_COLOR);
    });

    it('default_theme_keeps_legacy_colors', 0, () => {
      const light: ThemeColorRoles = ThemeColorMath.roles(DEFAULT_THEME_COLOR, false);
      expect(light.accent).assertEqual('#0A59F7');
      expect(light.fill).assertEqual('#0A59F7');
      expect(light.tint).assertEqual('#1A0A59F7');
      const dark: ThemeColorRoles = ThemeColorMath.roles(DEFAULT_THEME_COLOR, true);
      expect(dark.accent).assertEqual('#3F7CFF');
      expect(dark.fill).assertEqual('#3F7CFF');
      expect(dark.tint).assertEqual('#333F7CFF');
    });

    it('custom_theme_keeps_text_readable', 0, () => {
      const colors: string[] = ['#FFFF00', '#00FF00', '#FF00FF', '#123456', '#FFFFFF', '#000000'];
      for (let i = 0; i < colors.length; i += 1) {
        const light: ThemeColorRoles = ThemeColorMath.roles(colors[i], false);
        expect(ThemeColorMath.contrast(light.accent, '#FFFFFF') >= 4.4).assertTrue();
        expect(ThemeColorMath.contrast(light.fill, '#FFFFFF') >= 4.4).assertTrue();
        const dark: ThemeColorRoles = ThemeColorMath.roles(colors[i], true);
        expect(ThemeColorMath.contrast(dark.accent, '#1E2128') >= 4.4).assertTrue();
        expect(ThemeColorMath.contrast(dark.fill, '#FFFFFF') >= 4.4).assertTrue();
      }
    });

    it('tint_alpha_matches_mode', 0, () => {
      expect(ThemeColorMath.roles('#FF0000', false).tint.startsWith('#1A')).assertTrue();
      expect(ThemeColorMath.roles('#FF0000', true).tint.startsWith('#33')).assertTrue();
    });

    it('lighten_and_hue_shift_stay_hex', 0, () => {
      expect(ThemeColorMath.lighten('#FF0000', 0.08).length).assertEqual(7);
      expect(ThemeColorMath.hueShift('#FF0000', 120).length).assertEqual(7);
      expect(ThemeColorMath.withAlpha('#FF0000', 0x1A)).assertEqual('#1AFF0000');
    });

    it('logo_matches_launcher_variants', 0, () => {
      const classic: LogoStyle = logoStyleOf(LogoKind.CLASSIC);
      expect(classic.colorStart).assertEqual('#0D4DC6');
      expect(classic.markColor).assertEqual('#FFFFFF');
      expect(logoStyleOf(LogoKind.AURORA).colorEnd).assertEqual('#786BE8');
      expect(logoStyleOf(LogoKind.SUNSET).colorStart).assertEqual('#B93569');
      const mono: LogoStyle = logoStyleOf(LogoKind.MONO);
      expect(ThemeColorMath.contrast(mono.markColor, mono.colorStart) >= 4.4).assertTrue();
    });
  });
}
