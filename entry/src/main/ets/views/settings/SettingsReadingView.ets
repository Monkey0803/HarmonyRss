/*
 * SettingsReadingView.ets — 「阅读与列表」二级页（纯展示 + 事件上报）。
 *
 * 内容：正文排版（字号 / 行距 / 字体 / 栏宽 / 对齐 / 阅读主题 / 阅读时常亮）与文章列表样式
 * （行样式 / 摘要行数 / 密度）。与详情页「阅读排版」半模态面板改的是同一组偏好。
 */

import {
  LIST_DENSITY_OPTIONS,
  READER_ALIGN_OPTIONS,
  READER_FAMILY_OPTIONS,
  READER_FONT_OPTIONS,
  READER_LINE_OPTIONS,
  READER_THEME_OPTIONS,
  READER_WIDTH_OPTIONS,
  ROW_LAYOUT_OPTIONS,
  SUMMARY_LINES_OPTIONS
} from '../../model/SettingsOptions';
import { settingsViewModel } from '../../viewmodel/SettingsViewModel';
import { safeArea } from '../../service/SafeAreaController';
import { OptionSelectRow, SettingField, SettingsSectionTitle, SwitchSettingRow } from './SettingsRows';

@ComponentV2
export struct SettingsReadingView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  build() {
    Scroll(this.scroller) {
      Column() {
        // 透明标题栏占位：内容可以穿过标题栏下方。
        Row().width('100%').height(safeArea.contentTopInsetVp)

        SettingsSectionTitle({ title: $r('app.string.section_reading') })
        Column() {
          OptionSelectRow({
            icon: $r('sys.symbol.textformat'),
            title: $r('app.string.row_reader_font'),
            choice: READER_FONT_OPTIONS,
            field: SettingField.READER_FONT,
            onPick: (id: string) => {
              settingsViewModel.setReaderFont(id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          OptionSelectRow({
            icon: $r('sys.symbol.text_alignleft'),
            title: $r('app.string.row_reader_line'),
            choice: READER_LINE_OPTIONS,
            field: SettingField.READER_LINE,
            onPick: (id: string) => {
              settingsViewModel.setReaderLine(id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          OptionSelectRow({
            icon: $r('sys.symbol.textformat'),
            title: $r('app.string.row_reader_family'),
            choice: READER_FAMILY_OPTIONS,
            field: SettingField.READER_FAMILY,
            onPick: (id: string) => {
              settingsViewModel.setReaderFontFamily(id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          OptionSelectRow({
            icon: $r('sys.symbol.arrow_down_and_line_horizontal_and_arrow_up'),
            title: $r('app.string.row_reader_width'),
            choice: READER_WIDTH_OPTIONS,
            field: SettingField.READER_WIDTH,
            onPick: (id: string) => {
              settingsViewModel.setReaderWidth(id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          OptionSelectRow({
            icon: $r('sys.symbol.text_alignleft'),
            title: $r('app.string.row_reader_align'),
            choice: READER_ALIGN_OPTIONS,
            field: SettingField.READER_ALIGN,
            onPick: (id: string) => {
              settingsViewModel.setReaderAlign(id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          OptionSelectRow({
            icon: $r('sys.symbol.paintpalette'),
            title: $r('app.string.row_reader_theme'),
            choice: READER_THEME_OPTIONS,
            field: SettingField.READER_THEME,
            onPick: (id: string) => {
              settingsViewModel.setReaderTheme(id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          SwitchSettingRow({
            icon: $r('sys.symbol.sun_max'),
            title: $r('app.string.row_reader_keep_on'),
            field: SettingField.READER_KEEP_ON,
            onToggle: (value: boolean) => {
              settingsViewModel.setReaderKeepScreenOn(value);
            }
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        SettingsSectionTitle({ title: $r('app.string.section_list') })
        Column() {
          OptionSelectRow({
            icon: $r('sys.symbol.picture'),
            title: $r('app.string.row_list_layout'),
            choice: ROW_LAYOUT_OPTIONS,
            field: SettingField.ROW_LAYOUT,
            onPick: (id: string) => {
              settingsViewModel.setListRowLayout(id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          OptionSelectRow({
            icon: $r('sys.symbol.text_alignleft'),
            title: $r('app.string.row_summary_lines'),
            choice: SUMMARY_LINES_OPTIONS,
            field: SettingField.SUMMARY_LINES,
            onPick: (id: string) => {
              settingsViewModel.setListSummaryLines(id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          OptionSelectRow({
            icon: $r('sys.symbol.slider_horizontal_2'),
            title: $r('app.string.row_list_density'),
            choice: LIST_DENSITY_OPTIONS,
            field: SettingField.LIST_DENSITY,
            onPick: (id: string) => {
              settingsViewModel.setListDensity(id);
            }
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        // 底部预留：避让系统导航条。
        Blank().height(safeArea.contentBottomInsetVp)
      }
      .width('100%')
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    // Scroll 默认把「内容比视口短」的内容整体居中，会让首屏顶部多出一条空白；
    // 这里固定从顶部开始排。
    .align(Alignment.TopStart)
    .clip(false)
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
