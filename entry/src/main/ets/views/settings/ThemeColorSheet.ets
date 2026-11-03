/*
 * ThemeColorSheet.ets — 主题色半模态面板（纯状态管理 V2）。
 *
 * 内容：预设色块 + 实时预览 + 系统取色组件 HdsColorPicker。
 * 交互：
 *   - 预设点击 → onCommit（立即落盘）；
 *   - 取色器选择 → onPreview（只改内存，避免拖动时频繁写盘 / 刷卡片）；
 *   - 完成 / 关闭 → 由父组件提交当前预览色。
 *
 * HdsColorPicker 从 API 26 开始提供：低版本只保留预设色块并给出提示。
 */

import { deviceInfo } from '@kit.BasicServicesKit';
import { HdsColorPicker } from '@kit.UIDesignKit';
import { themePalette } from '../../model/ThemePalette';
import { THEME_COLOR_PRESETS, ThemeColorPreset } from '../../model/ThemeColorOptions';
import { ThemeColorMath } from '../../common/utils/ThemeColorMath';

@ComponentV2
export struct ThemeColorSheet {
  @Param currentColor: string = '#0A59F7';
  /** 取色器拖动中的实时预览。 */
  @Event onPreview: (hex: string) => void = () => {};
  /** 立即提交（预设点击）。 */
  @Event onCommit: (hex: string) => void = () => {};
  /** 关闭面板。 */
  @Event onClose: () => void = () => {};

  /** 当前系统是否提供 HDS 取色组件。 */
  private pickerAvailable(): boolean {
    return deviceInfo.apiAvailable('26.0.0');
  }

  private isCurrent(hex: string): boolean {
    return hex.trim().toUpperCase() === this.currentColor.trim().toUpperCase();
  }

  /** 取色器收藏页的初始色：当前色 + 六个预设。 */
  private favoriteColors(): string[] {
    const result: string[] = [];
    result.push(this.currentColor);
    for (let i = 0; i < THEME_COLOR_PRESETS.length; i += 1) {
      const hex: string = THEME_COLOR_PRESETS[i].hex;
      if (result.indexOf(hex) < 0) {
        result.push(hex);
      }
    }
    return result;
  }

  @Builder
  PresetSwatch(preset: ThemeColorPreset) {
    Stack() {
      Row()
        .width($r('app.float.theme_color_swatch_size'))
        .height($r('app.float.theme_color_swatch_size'))
        .borderRadius($r('app.float.theme_color_swatch_radius'))
        .backgroundColor(preset.hex)
      if (this.isCurrent(preset.hex)) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([$r('app.color.hm_on_brand')])
      }
    }
    .width($r('app.float.theme_color_swatch_hit'))
    .height($r('app.float.theme_color_swatch_hit'))
    .accessibilityText(preset.label)
    .accessibilitySelected(this.isCurrent(preset.hex))
    .onClick(() => {
      this.onCommit(preset.hex);
    })
  }

  /** 预览条：实心按钮 / 品牌文字 / 选中浅底三种真实用法。 */
  @Builder
  PreviewStrip() {
    Row({ space: $r('app.float.space_s') }) {
      Row() {
        Text('Aa')
          .fontSize($r('app.float.font_size_caption'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hm_on_brand'))
      }
      .height($r('app.float.theme_color_preview_height'))
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
      .backgroundColor(themePalette.fill())
      .borderRadius($r('app.float.radius_card'))

      Text('Aa')
        .fontSize($r('app.float.font_size_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor(themePalette.accent())

      Row() {
        Text('Aa')
          .fontSize($r('app.float.font_size_body'))
          .fontColor(themePalette.accent())
      }
      .height($r('app.float.theme_color_preview_height'))
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
      .backgroundColor(themePalette.tint())
      .borderRadius($r('app.float.radius_card'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column({ space: $r('app.float.space_m') }) {
      Row() {
        Text($r('app.string.theme_color_picker_title'))
          .fontSize($r('app.float.font_size_title'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hm_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        // 完成用 HM Symbol 图标；容器与下方「自定义」行右侧的取色入口保持同一边距，
        // 保证标题行与自定义行右边缘对齐。
        Row() {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize($r('app.float.icon_size'))
            .fontColor([themePalette.accent()])
        }
        .width($r('app.float.theme_color_done_hit'))
        .height($r('app.float.theme_color_done_hit'))
        .justifyContent(FlexAlign.Center)
        .margin({ right: $r('app.float.space_m') })
        .accessibilityText($r('app.string.theme_color_done'))
        .onClick(() => {
          this.onCommit(this.currentColor);
          this.onClose();
        })
      }
      .width('100%')
      .height($r('app.float.theme_color_done_hit'))

      Text($r('app.string.theme_color_presets'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      Row() {
        ForEach(THEME_COLOR_PRESETS, (preset: ThemeColorPreset) => {
          this.PresetSwatch(preset)
        }, (preset: ThemeColorPreset) => preset.id)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)

      Text($r('app.string.theme_color_preview'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      this.PreviewStrip()

      if (this.pickerAvailable()) {
        Row() {
          Text($r('app.string.theme_color_custom'))
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_text_primary'))
            .layoutWeight(1)
          // HdsColorPicker 自身是一个 24vp 的取色入口：点开后由系统弹出色板 / 滑杆 / Hex 面板。
          // 放进与「完成」图标同尺寸（44vp）的容器并居中，保证上下两个入口中心对齐；
          // 不能直接给 HdsColorPicker 设大尺寸——它内部内容靠左，会被推离右边缘。
          Stack() {
            HdsColorPicker({
              initialColor: this.currentColor,
              initialFavoriteColors: this.favoriteColors(),
              onColorSelected: (selected: string) => {
                const normalized: string = ThemeColorMath.normalize(selected, this.currentColor);
                if (normalized !== this.currentColor) {
                  this.onPreview(normalized);
                }
              }
            })
              .width($r('app.float.theme_color_picker_size'))
              .height($r('app.float.theme_color_picker_size'))
          }
          .width($r('app.float.theme_color_done_hit'))
          .height($r('app.float.theme_color_done_hit'))
        }
        .width('100%')
        .height(72)
        .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
        .alignItems(VerticalAlign.Center)
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))
      } else {
        Text($r('app.string.theme_color_picker_unavailable'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      }
      Blank().layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({
      left: $r('app.float.space_l'),
      right: $r('app.float.space_l'),
      top: $r('app.float.space_m'),
      bottom: $r('app.float.space_m')
    })
    .alignItems(HorizontalAlign.Start)
  }
}
