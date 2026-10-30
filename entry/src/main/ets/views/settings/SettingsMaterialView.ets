/*
 * SettingsMaterialView.ets — 「材质与动效」二级页（纯展示 + 事件上报）。
 *
 * 内容：沉浸光感总开关、材质类型 / 等级、点光源、标题栏与状态栏随内容滚动、效果预览入口。
 * 这些项集中在标题栏 / 页签栏的视觉表现上，因此单独成页。
 */

import {
  MATERIAL_LEVEL_OPTIONS,
  MATERIAL_TYPE_OPTIONS
} from '../../model/SettingsOptions';
import { settingsViewModel } from '../../viewmodel/SettingsViewModel';
import { RouterConstants } from '../../common/constants/RouterConstants';
import { safeArea } from '../../service/SafeAreaController';
import { NavSettingRow, OptionSelectRow, SettingField, SettingsSectionTitle, SwitchSettingRow } from './SettingsRows';

@ComponentV2
export struct SettingsMaterialView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  build() {
    Scroll(this.scroller) {
      Column() {
        // 透明标题栏占位：内容可以穿过标题栏下方。
        Row().width('100%').height(safeArea.contentTopInsetVp)

        SettingsSectionTitle({ title: $r('app.string.section_appearance') })
        Column() {
          SwitchSettingRow({
            icon: $r('sys.symbol.rays'),
            title: $r('app.string.row_immersive'),
            field: SettingField.IMMERSIVE,
            onToggle: (value: boolean) => {
              settingsViewModel.setImmersiveOn(value);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          OptionSelectRow({
            icon: $r('sys.symbol.circle'),
            title: $r('app.string.row_material_type'),
            choice: MATERIAL_TYPE_OPTIONS,
            field: SettingField.MATERIAL_TYPE,
            onPick: (id: string) => {
              settingsViewModel.setMaterialType(id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          OptionSelectRow({
            icon: $r('sys.symbol.slider_horizontal_2'),
            title: $r('app.string.row_material_level'),
            choice: MATERIAL_LEVEL_OPTIONS,
            field: SettingField.MATERIAL_LEVEL,
            onPick: (id: string) => {
              settingsViewModel.setMaterialLevel(id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          SwitchSettingRow({
            icon: $r('sys.symbol.lightbulb'),
            title: $r('app.string.row_point_light'),
            field: SettingField.POINT_LIGHT,
            onToggle: (value: boolean) => {
              settingsViewModel.setPointLightEnabled(value);
            }
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        Text(settingsViewModel.globalImmersive
          ? $r('app.string.aux_global_immersive_on')
          : $r('app.string.aux_global_immersive_off'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })

        // 设备算力档：低算力设备上材质等级会被钳到「自适应」（见 MaterialController.clampLevel）。
        if (settingsViewModel.globalLevelId.length > 0) {
          Row({ space: $r('app.float.space_xxs') }) {
            Text($r('app.string.aux_material_level'))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
            Text(MATERIAL_LEVEL_OPTIONS.labelOf(settingsViewModel.globalLevelId))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
          }
          .width('100%')
          .margin({ top: $r('app.float.space_xxs'), left: $r('app.float.space_xs') })
        }

        SettingsSectionTitle({ title: $r('app.string.section_navigation') })
        Column() {
          SwitchSettingRow({
            icon: $r('sys.symbol.arrow_down_and_line_horizontal_and_arrow_up'),
            title: $r('app.string.row_title_bar_scroll'),
            field: SettingField.TITLE_BAR_SCROLL,
            onToggle: (value: boolean) => {
              settingsViewModel.setTitleBarScroll(value);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          SwitchSettingRow({
            icon: $r('sys.symbol.arrow_down_and_line_horizontal_and_arrow_up'),
            title: $r('app.string.row_status_bar_scroll'),
            field: SettingField.STATUS_BAR_SCROLL,
            onToggle: (value: boolean) => {
              settingsViewModel.setStatusBarScroll(value);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          NavSettingRow({
            icon: $r('sys.symbol.lightbulb'),
            title: $r('app.string.row_effect_preview'),
            onOpen: () => {
              this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_EFFECT, ''));
            }
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        Text($r('app.string.shortcut_hint'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })

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
