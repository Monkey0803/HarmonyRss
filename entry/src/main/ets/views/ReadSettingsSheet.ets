/*
 * ReadSettingsSheet.ets — 详情页「阅读排版」半模态面板（纯 V2）。
 *
 * 为什么是半模态而不是菜单：字号 / 行距改成连续值后需要 Slider + 实时预览，
 * 菜单放不下；而且半模态属于沉浸光感的生效区域（面板材质由父组件的
 * MaterialController.sheetOptions 注入，见 ArticleDetailView）。
 *
 * 交互约定：
 *   - 面板里改的是 appSettings（@Trace），预览区立刻按新排版显示；
 *   - 滑块拖动过程中**节流**通知父组件（正文只是原地替换 <style>，很便宜），
 *     松手（SliderChangeMode.End / Click）才落盘；
 *   - 栏宽 / 对齐 / 主题 / 字体族仍是离散档位，点一下就生效。
 */

import {
  ChoiceOption,
  ChoiceSet,
  READER_ALIGN_OPTIONS,
  READER_FAMILY_OPTIONS,
  READER_THEME_OPTIONS,
  READER_WIDTH_OPTIONS
} from '../model/SettingsOptions';
import { ReaderAlign, ReaderTypography } from '../common/constants/SettingsConstants';
import { appSettings } from '../model/AppSettings';
import { settingsViewModel } from '../viewmodel/SettingsViewModel';

/** 拖动过程中应用排版的节流间隔（毫秒）。 */
const APPLY_THROTTLE_MS: number = 100;

/** 面板里一组离散档位（栏宽 / 对齐 / 主题 / 字体族）。 */
interface ReadSettingGroup {
  id: string;
  title: ResourceStr;
  choice: ChoiceSet;
  pick: (id: string) => void;
}

@ComponentV2
export struct ReadSettingsSheet {
  /** 网页原文模式：栏宽 / 对齐 / 主题 / 字体族不生效，面板里给出说明。 */
  @Param webMode: boolean = false;
  /** 排版变化上报：父组件据此原地替换 Reader 文档样式 / 重新注入网页样式。 */
  @Event onApply: () => void = () => {};

  /** 拖动过程中应用节流（毫秒）：够跟手，又不会每帧都注入一次样式。 */
  private lastApplyAt: number = 0;

  /**
   * 应用排版改动：拖动中节流应用，松手/点按时应用并落盘。
   * 正文侧只是替换一条 <style>，不再是整篇重建，所以可以边拖边生效。
   */
  private applyChange(mode: SliderChangeMode): void {
    if (mode === SliderChangeMode.Begin) {
      return;
    }
    if (mode === SliderChangeMode.Moving) {
      const now: number = Date.now();
      if (now - this.lastApplyAt < APPLY_THROTTLE_MS) {
        return;
      }
      this.lastApplyAt = now;
      this.onApply();
      return;
    }
    settingsViewModel.persistReaderTypography();
    this.onApply();
  }

  private fontPx(): number {
    return ReaderTypography.fontSizePx(appSettings.readerFontScale);
  }

  private lineHeight(): number {
    return this.fontPx() * ReaderTypography.lineHeightOf(appSettings.readerLineScale);
  }

  /** 当前选中值：按组 id 读设置项（在 build 里读，状态变化即刷新）。 */
  private selectedOf(groupId: string): string {
    if (groupId === 'width') {
      return appSettings.readerWidth;
    }
    if (groupId === 'align') {
      return appSettings.readerAlign;
    }
    if (groupId === 'theme') {
      return appSettings.readerTheme;
    }
    return appSettings.readerFontFamily;
  }

  private groups(): ReadSettingGroup[] {
    const result: ReadSettingGroup[] = [
      {
        id: 'width',
        title: $r('app.string.row_reader_width'),
        choice: READER_WIDTH_OPTIONS,
        pick: (id: string) => {
          settingsViewModel.setReaderWidth(id);
        }
      },
      {
        id: 'align',
        title: $r('app.string.row_reader_align'),
        choice: READER_ALIGN_OPTIONS,
        pick: (id: string) => {
          settingsViewModel.setReaderAlign(id);
        }
      },
      {
        id: 'theme',
        title: $r('app.string.row_reader_theme'),
        choice: READER_THEME_OPTIONS,
        pick: (id: string) => {
          settingsViewModel.setReaderTheme(id);
        }
      },
      {
        id: 'family',
        title: $r('app.string.row_reader_family'),
        choice: READER_FAMILY_OPTIONS,
        pick: (id: string) => {
          settingsViewModel.setReaderFontFamily(id);
        }
      }
    ];
    return result;
  }

  /** 一行档位：左标题 + 右侧可点选 chips。 */
  @Builder
  GroupRow(group: ReadSettingGroup) {
    Row({ space: $r('app.float.space_s') }) {
      Text(group.title)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width(this.titleWidth())

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(group.choice.options, (option: ChoiceOption) => {
          Text(option.label)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor(this.selectedOf(group.id) === option.id
              ? $r('app.color.hm_on_brand')
              : $r('app.color.hm_text_primary'))
            .padding({
              left: $r('app.float.space_m'),
              right: $r('app.float.space_m'),
              top: $r('app.float.space_xs'),
              bottom: $r('app.float.space_xs')
            })
            .backgroundColor(this.selectedOf(group.id) === option.id
              ? $r('app.color.hm_brand')
              : $r('app.color.hm_value_chip_background'))
            .borderRadius($r('app.float.radius_chip'))
            .margin({ right: $r('app.float.space_xs'), bottom: $r('app.float.space_xs') })
            .onClick(() => {
              group.pick(option.id);
              this.onApply();
            })
        }, (option: ChoiceOption) => group.id + option.id)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  private titleWidth(): Length {
    return $r('app.float.read_panel_label_width');
  }

  build() {
    Column({ space: $r('app.float.space_m') }) {
      Text($r('app.string.read_panel_title'))
        .fontSize($r('app.float.font_size_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      // 预览区：跟着面板里的改动立即重排
      Text($r('app.string.read_panel_preview_text'))
        .fontSize(this.fontPx())
        .lineHeight(this.lineHeight())
        .fontColor($r('app.color.hm_text_primary'))
        .textAlign(appSettings.readerAlign === ReaderAlign.JUSTIFY ? TextAlign.JUSTIFY : TextAlign.Start)
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding($r('app.float.space_m'))
        .backgroundColor($r('app.color.hm_value_chip_background'))
        .borderRadius($r('app.float.radius_card'))

      // 正文字号（连续）
      Row() {
        Text($r('app.string.row_reader_font'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        Blank()
        Text($r('app.string.read_panel_font_value', this.fontPx().toFixed(1)))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_primary'))
      }
      .width('100%')

      Slider({
        value: appSettings.readerFontScale,
        min: ReaderTypography.FONT_SCALE_MIN,
        max: ReaderTypography.FONT_SCALE_MAX,
        step: 0.05,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => {
          settingsViewModel.setReaderFontScale(value);
          this.applyChange(mode);
        })

      // 行距（连续）
      Row() {
        Text($r('app.string.row_reader_line'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        Blank()
        Text($r('app.string.read_panel_line_value',
          ReaderTypography.lineHeightOf(appSettings.readerLineScale).toFixed(2)))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_primary'))
      }
      .width('100%')

      Slider({
        value: appSettings.readerLineScale,
        min: ReaderTypography.LINE_SCALE_MIN,
        max: ReaderTypography.LINE_SCALE_MAX,
        step: 0.05,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => {
          settingsViewModel.setReaderLineScale(value);
          this.applyChange(mode);
        })

      ForEach(this.groups(), (group: ReadSettingGroup) => {
        this.GroupRow(group)
      }, (group: ReadSettingGroup) => group.id)

      if (this.webMode) {
        Text($r('app.string.read_panel_web_hint'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      }

      Row() {
        Blank()
        Button($r('app.string.read_panel_reset'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .onClick(() => {
            settingsViewModel.setReaderFontScale(1.0);
            settingsViewModel.setReaderLineScale(1.7);
            settingsViewModel.setReaderWidth(READER_WIDTH_OPTIONS.defaultValue);
            settingsViewModel.setReaderAlign(READER_ALIGN_OPTIONS.defaultValue);
            settingsViewModel.setReaderTheme(READER_THEME_OPTIONS.defaultValue);
            settingsViewModel.setReaderFontFamily(READER_FAMILY_OPTIONS.defaultValue);
            this.onApply();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_l'),
      right: $r('app.float.space_l'),
      top: $r('app.float.space_m'),
      bottom: $r('app.float.space_l')
    })
    .alignItems(HorizontalAlign.Start)
  }
}
