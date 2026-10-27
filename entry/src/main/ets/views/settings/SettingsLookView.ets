/*
 * SettingsLookView.ets — 「外观与语言」二级页（纯展示 + 事件上报）。
 *
 * 内容：主题、全局背景图、品牌图标（应用图标）、语言、联网翻译入口。
 * 行为与原来设置页签的对应分区一致，逻辑全部在 SettingsViewModel。
 */

import { common } from '@kit.AbilityKit';
import {
  HdsSnackBar,
  SnackBarIconOptions,
  SnackBarMessageOptions,
  SnackBarOperationOptions,
  SnackBarStyleOptions,
  SnackBarOperationType
} from '@kit.UIDesignKit';
import { appSettings } from '../../model/AppSettings';
import {
  BACKGROUND_OPTIONS,
  ChoiceOption,
  LANGUAGE_OPTIONS,
  LOGO_OPTIONS,
  THEME_OPTIONS
} from '../../model/SettingsOptions';
import { settingsViewModel } from '../../viewmodel/SettingsViewModel';
import { AppLogo } from '../../common/components/AppLogo';
import { CommonConstants } from '../../common/constants/CommonConstants';
import { RouterConstants } from '../../common/constants/RouterConstants';
import { BackgroundKind } from '../../common/constants/SettingsConstants';
import { safeArea } from '../../service/SafeAreaController';
import { NavSettingRow, OptionSelectRow, SettingField, SettingsSectionTitle } from './SettingsRows';

/** App logo 选择区：四个变体的可视化预览，选中项加品牌色描边。 */
@ComponentV2
struct LogoPickerRow {
  @Event onPick: (id: string) => void = () => {};

  @Builder
  LogoTile(option: ChoiceOption) {
    Column({ space: $r('app.float.space_s') }) {
      Stack() {
        AppLogo({
          logoKind: option.id,
          logoSize: CommonConstants.LOGO_TILE_SIZE,
          cornerRadius: CommonConstants.LOGO_TILE_RADIUS
        })
      }
      .padding($r('app.float.space_xs'))
      .borderRadius($r('app.float.radius_card'))
      .borderWidth(option.id === appSettings.logoKind ? 2 : 0)
      .borderColor($r('app.color.hm_brand'))
      .backgroundColor(option.id === appSettings.logoKind
        ? $r('app.color.hm_menu_item_selected')
        : $r('app.color.hm_page_transparent'))

      Text(option.label)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor(option.id === appSettings.logoKind
          ? $r('app.color.hm_brand')
          : $r('app.color.hm_text_secondary'))
    }
    .layoutWeight(1)
    .onClick(() => {
      this.onPick(option.id);
    })
  }

  build() {
    Row() {
      ForEach(LOGO_OPTIONS.options, (option: ChoiceOption) => {
        this.LogoTile(option)
      }, (option: ChoiceOption) => option.id)
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_s'),
      right: $r('app.float.space_s'),
      top: $r('app.float.space_m'),
      bottom: $r('app.float.space_m')
    })
  }
}

@ComponentV2
export struct SettingsLookView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  private hostContext(): common.UIAbilityContext {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    return context as common.UIAbilityContext;
  }

  /** 桌面图标未能切换时的即时提示（HdsSnackBar，比 Toast 更能承载「为什么没成功」）。 */
  private launcherIconSnack(): void {
    const bar: HdsSnackBar = new HdsSnackBar(this.getUIContext());
    const icon: SnackBarIconOptions = { icon: $r('sys.symbol.exclamationmark_circle') };
    const message: SnackBarMessageOptions = { title: $r('app.string.toast_logo_launcher_failed') };
    const operation: SnackBarOperationOptions = {
      operationType: SnackBarOperationType.CLOSE_BUTTON_ONLY,
      closeButtonAccessibilityText: $r('app.string.snack_dismiss')
    };
    const style: SnackBarStyleOptions = { duration: 4000 };
    bar.show(icon, message, operation, style);
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        // 透明标题栏占位：内容可以穿过标题栏下方。
        Row().width('100%').height(safeArea.contentTopInsetVp)

        SettingsSectionTitle({ title: $r('app.string.section_appearance') })
        Column() {
          OptionSelectRow({
            icon: $r('sys.symbol.paintpalette'),
            title: $r('app.string.row_theme'),
            choice: THEME_OPTIONS,
            field: SettingField.THEME,
            onPick: (id: string) => {
              settingsViewModel.setTheme(this.hostContext(), id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          OptionSelectRow({
            icon: $r('sys.symbol.picture'),
            title: $r('app.string.row_global_background'),
            choice: BACKGROUND_OPTIONS,
            field: SettingField.BACKGROUND,
            onPick: (id: string) => {
              // 「自定义图片」需要先打开系统图库选图；取消时保持当前背景不变。
              if (id === BackgroundKind.CUSTOM) {
                settingsViewModel.pickCustomBackground(this.hostContext());
              } else {
                settingsViewModel.setBackgroundKind(id);
              }
            }
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        SettingsSectionTitle({ title: $r('app.string.section_branding') })
        Column() {
          LogoPickerRow({
            onPick: (id: string) => {
              settingsViewModel.setLogoKind(id).then((applied: boolean) => {
                if (!applied) {
                  this.launcherIconSnack();
                }
              });
            }
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        Text($r('app.string.aux_logo_launcher_hint'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })

        SettingsSectionTitle({ title: $r('app.string.section_language') })
        Column() {
          OptionSelectRow({
            icon: $r('sys.symbol.translate'),
            title: $r('app.string.row_language'),
            choice: LANGUAGE_OPTIONS,
            field: SettingField.LANGUAGE,
            onPick: (id: string) => {
              settingsViewModel.setLanguage(id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          // 联网翻译：默认关闭；服务 / Key / 缓存都在独立页面。
          NavSettingRow({
            icon: $r('sys.symbol.translate'),
            title: $r('app.string.translate_settings_title'),
            onOpen: () => {
              this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_TRANSLATE_SETTINGS, ''));
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
