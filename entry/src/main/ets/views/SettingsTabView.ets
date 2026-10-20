/*
 * SettingsTabView.ets — 设置页签（纯展示 + 事件上报）。
 *
 * 选项切换行（主题 / 全局背景图 / 材质类型 / 沉浸光感材质 / 语言）用 bindMenu 弹系统 Menu：
 * 选中项用「整行圆角色块」高亮，且高亮块上下不再画分隔线。
 * 布尔行（沉浸光感 / 点光源效果 / 智感握姿 / 防窥保护）用 Toggle，开启时整行同样加选中色块。
 * 业务逻辑一律在 SettingsViewModel，这里只读 appSettings / antiPeep 的状态、把用户操作上报给 ViewModel。
 * 尺寸与颜色全部走 resources。
 *
 * 关键约束：各行的当前值由**行组件自己**读 appSettings，而不是由父级按值传进来。
 * ArkUI 规定 @Builder 传入两个及以上参数时不触发动态刷新（官方文档「@Builder 参数传递规则」），
 * 原先的行就是 5 参 @Builder，所以选完值后行文案与菜单高亮都停在旧值上；这里改成
 * @ComponentV2 + @Param/@Event，并把读 @Trace 的语句放在组件自己的 build 里。
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
import { appSettings } from '../model/AppSettings';
import { ARCHIVE_OPTIONS, LIST_DENSITY_OPTIONS, ROW_LAYOUT_OPTIONS, SUMMARY_LINES_OPTIONS, ChoiceOption, ChoiceSet, THEME_OPTIONS, LANGUAGE_OPTIONS, MATERIAL_TYPE_OPTIONS, MATERIAL_LEVEL_OPTIONS, BACKGROUND_OPTIONS, LOGO_OPTIONS, AUTO_REFRESH_OPTIONS, READER_FONT_OPTIONS, READER_LINE_OPTIONS, READER_FAMILY_OPTIONS, READER_WIDTH_OPTIONS, READER_ALIGN_OPTIONS, READER_THEME_OPTIONS } from '../model/SettingsOptions';
import { settingsViewModel } from '../viewmodel/SettingsViewModel';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { articleStore } from '../service/ArticleStore';
import { antiPeep } from '../service/AntiPeep';
import { safeArea } from '../service/SafeAreaController';
import { AppLogo } from '../common/components/AppLogo';
import { ToastUtil } from '../common/utils/ToastUtil';
import { CommonConstants } from '../common/constants/CommonConstants';
import { RouterConstants } from '../common/constants/RouterConstants';
import { BackgroundKind } from '../common/constants/SettingsConstants';
import { DateUtil } from '../common/utils/DateUtil';
import { MaterialController } from '../service/MaterialController';

/** 设置页每一行绑定到 appSettings 的哪个字段。 */
enum SettingField {
  THEME = 'theme',
  BACKGROUND = 'background',
  MATERIAL_TYPE = 'materialType',
  MATERIAL_LEVEL = 'materialLevel',
  LANGUAGE = 'language',
  IMMERSIVE = 'immersive',
  POINT_LIGHT = 'pointLight',
  GRIP = 'grip',
  ANTI_PEEP = 'antiPeep',
  TITLE_BAR_SCROLL = 'titleBarScroll',
  STATUS_BAR_SCROLL = 'statusBarScroll',
  AUTO_REFRESH = 'autoRefresh',
  ARCHIVE_RULE = 'archiveRule',
  ROW_LAYOUT = 'rowLayout',
  SUMMARY_LINES = 'summaryLines',
  LIST_DENSITY = 'listDensity',
  READER_FONT = 'readerFont',
  READER_LINE = 'readerLine',
  READER_FAMILY = 'readerFamily',
  READER_WIDTH = 'readerWidth',
  READER_ALIGN = 'readerAlign',
  READER_THEME = 'readerTheme',
  READER_KEEP_ON = 'readerKeepScreenOn',
  NOTIFY_NEW = 'notifyNew'
}

/** 行首图标 + 标题。纯静态内容，不随状态变化，因此可以用多参全局 @Builder。 */
@Builder
function SettingLeading(icon: Resource, title: ResourceStr) {
  Row({ space: $r('app.float.space_m') }) {
    SymbolGlyph(icon)
      .fontSize($r('app.float.icon_size'))
      .fontColor([$r('app.color.hm_brand')])
    Text(title)
      .fontSize($r('app.float.font_size_body'))
      .fontColor($r('app.color.hm_text_primary'))
  }
}

/** 下拉选项行：自己读 appSettings 的当前值并弹 Menu。 */
@ComponentV2
struct OptionSelectRow {
  @Param icon: Resource = $r('sys.symbol.house');
  @Param title: ResourceStr = '';
  @Param choice: ChoiceSet = THEME_OPTIONS;
  @Param field: SettingField = SettingField.THEME;
  @Event onPick: (id: string) => void = () => {};

  /** 当前选中项 id。在 build 中被调用，所以本组件会随 @Trace 一起刷新。 */
  private currentId(): string {
    switch (this.field) {
      case SettingField.BACKGROUND:
        return appSettings.backgroundKind;
      case SettingField.MATERIAL_TYPE:
        return appSettings.materialType;
      case SettingField.MATERIAL_LEVEL:
        return appSettings.materialLevel;
      case SettingField.LANGUAGE:
        return appSettings.languageMode;
      case SettingField.ARCHIVE_RULE:
        return appSettings.archiveRule;
      case SettingField.ROW_LAYOUT:
        return appSettings.listRowLayout;
      case SettingField.SUMMARY_LINES:
        return appSettings.listSummaryLines;
      case SettingField.LIST_DENSITY:
        return appSettings.listDensity;
      case SettingField.AUTO_REFRESH:
        return appSettings.autoRefresh;
      case SettingField.READER_FONT:
        return appSettings.readerFont;
      case SettingField.READER_LINE:
        return appSettings.readerLine;
      case SettingField.READER_FAMILY:
        return appSettings.readerFontFamily;
      case SettingField.READER_WIDTH:
        return appSettings.readerWidth;
      case SettingField.READER_ALIGN:
        return appSettings.readerAlign;
      case SettingField.READER_THEME:
        return appSettings.readerTheme;
      default:
        return appSettings.themeMode;
    }
  }

  /**
   * 该项下面要不要画分隔线。
   * 高亮块自身、以及紧邻高亮块的那一段都不画，避免线穿过圆角色块（与参考效果一致）。
   */
  private needDivider(index: number, current: string): boolean {
    const last: number = this.choice.options.length - 1;
    if (index >= last) {
      return false;
    }
    if (this.choice.options[index].id === current) {
      return false;
    }
    return this.choice.options[index + 1].id !== current;
  }

  /** 菜单项内容：整行圆角高亮块 + 可选分隔线。 */
  @Builder
  MenuItemContent(option: ChoiceOption, selected: boolean, showDivider: boolean) {
    Stack({ alignContent: Alignment.Bottom }) {
      Row() {
        Text(option.label)
          .fontSize($r('app.float.font_size_body'))
          .fontWeight(selected ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(selected ? $r('app.color.hm_brand') : $r('app.color.hm_text_primary'))
      }
      .width('100%')
      .height('100%')
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
      .alignItems(VerticalAlign.Center)
      .margin({ left: $r('app.float.space_xs'), right: $r('app.float.space_xs') })
      .backgroundColor(selected ? $r('app.color.hm_menu_item_selected') : $r('app.color.hm_page_transparent'))
      .borderRadius($r('app.float.radius_menu_item'))

      if (showDivider) {
        Divider()
          .color($r('app.color.hm_divider'))
          .margin({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
      }
    }
    .width('100%')
    .height($r('app.float.menu_item_height'))
    .onClick(() => {
      this.onPick(option.id);
    })
  }

  /** 一张选项表的系统 Menu：分隔线由每个菜单项自己画，不再用 menuItemDivider。 */
  @Builder
  OptionMenu() {
    Menu() {
      ForEach(this.choice.options, (option: ChoiceOption, index: number) => {
        MenuItem(this.MenuItemContent(option, option.id === this.currentId(), this.needDivider(index, this.currentId())))
      }, (option: ChoiceOption) => option.id)
    }
    // 不设宽度时 Menu 走默认「两列宽度」，弹出来占掉近 90% 屏宽；这里收成一条紧凑菜单。
    .width($r('app.float.menu_width'))
    .radius($r('app.float.radius_card'))
  }

  build() {
    Row() {
      SettingLeading(this.icon, this.title)
      Blank()
      // 当前值做成「胶囊底 + 实心倒三角」的取值控件（与系统设置页一致）。
      Row({ space: $r('app.float.space_xs') }) {
        Text(this.choice.labelOf(this.currentId()))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
        SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
          .fontSize($r('app.float.icon_size_tiny'))
          .fontColor([$r('app.color.hm_text_primary')])
      }
      .height($r('app.float.value_chip_height'))
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
      .backgroundColor($r('app.color.hm_value_chip_background'))
      .borderRadius($r('app.float.radius_chip'))
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    // 贴着被点的这一行弹出：右下对齐，从右侧的当前值 / 箭头下方展开。
    .bindMenu(this.OptionMenu(),
      MaterialController.menuOptions({ placement: Placement.BottomRight }, appSettings.immersiveOn))
  }
}

/** 布尔开关行：自己读 appSettings 的当前值。开启状态由 Toggle 自身表达，行不额外加背景块。 */
@ComponentV2
struct SwitchSettingRow {
  @Param icon: Resource = $r('sys.symbol.house');
  @Param title: ResourceStr = '';
  @Param field: SettingField = SettingField.IMMERSIVE;
  @Event onToggle: (value: boolean) => void = () => {};

  private isOn(): boolean {
    switch (this.field) {
      case SettingField.POINT_LIGHT:
        return appSettings.pointLightEnabled;
      case SettingField.GRIP:
        return appSettings.gripEnabled;
      case SettingField.ANTI_PEEP:
        return appSettings.antiPeepEnabled;
      case SettingField.TITLE_BAR_SCROLL:
        return appSettings.titleBarScrollsWithContent;
      case SettingField.STATUS_BAR_SCROLL:
        return appSettings.statusBarScrollsWithContent;
      case SettingField.NOTIFY_NEW:
        return appSettings.notifyNewArticles;
      case SettingField.READER_KEEP_ON:
        return appSettings.readerKeepScreenOn;
      default:
        return appSettings.immersiveOn;
    }
  }

  build() {
    Row() {
      Row() {
        SettingLeading(this.icon, this.title)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.isOn() })
          .selectedColor($r('app.color.hm_brand'))
          .onChange((value: boolean) => {
            this.onToggle(value);
          })
      }
      .width('100%')
      .height('100%')
      // 外层留 space_xs，这里补齐到 space_m，保证文字与选项行对齐。
      .padding({ left: $r('app.float.space_s'), right: $r('app.float.space_s') })
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({
      left: $r('app.float.space_xs'),
      right: $r('app.float.space_xs'),
      top: $r('app.float.space_xs'),
      bottom: $r('app.float.space_xs')
    })
  }
}

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
export struct SettingsTabView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  /** 标注条数（进页面时读一次，够用于入口行的展示）。 */
  @Local highlightCount: number = 0;

  /** 进设置页时刷新一次正文缓存占用（存储区展示用）与标注条数。 */
  aboutToAppear(): void {
    feedViewModel.refreshCacheStats();
    this.reloadHighlightCount();
  }

  private async reloadHighlightCount(): Promise<void> {
    this.highlightCount = await articleStore.countHighlights();
  }

  /** 开启通知前先申请系统授权；失败则提示并保持关闭。 */
  private async toggleNotify(value: boolean): Promise<void> {
    const granted: boolean = await settingsViewModel.setNotifyNewArticles(value, this.hostContext());
    if (value && !granted) {
      ToastUtil.show(this.getUIContext(), $r('app.string.toast_notify_denied'));
    }
  }

  /** 手动刷新：抓取全部订阅源，完成后用 SnackBar 反馈。 */
  private refreshNow(): void {
    if (feedViewModel.loading) {
      ToastUtil.show(this.getUIContext(), $r('app.string.toast_refreshing'));
      return;
    }
    feedViewModel.refreshAll().then(() => {
      const bar: HdsSnackBar = new HdsSnackBar(this.getUIContext());
      const icon: SnackBarIconOptions = { icon: $r('sys.symbol.checkmark_circle') };
      const message: SnackBarMessageOptions = { title: $r('app.string.snack_refreshed') };
      const operation: SnackBarOperationOptions = {
        operationType: SnackBarOperationType.CLOSE_BUTTON_ONLY,
        closeButtonAccessibilityText: $r('app.string.snack_dismiss')
      };
      bar.show(icon, message, operation, { duration: 2000 } as SnackBarStyleOptions);
    });
  }

  private hostContext(): common.UIAbilityContext {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    return context as common.UIAbilityContext;
  }

  /** 缓存占用文案：条数 + 粗略体积（KB/MB）。 */
  private cacheSummary(): ResourceStr {
    const count: number = feedViewModel.cachedArticles;
    const kb: number = Math.round(feedViewModel.cachedChars / 1024);
    const size: string = kb < 1024 ? (kb.toString() + 'KB') : ((kb / 1024).toFixed(1) + 'MB');
    return $r('app.string.cache_summary', count, size);
  }

  /** 清理正文缓存（保留收藏）：二次确认后执行，并即时刷新占用。 */
  private confirmClearCache(): void {
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const confirmButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_confirm'),
      fontColor: $r('app.color.hm_brand'),
      action: () => {
        feedViewModel.clearCachedContent().then((cleared: number) => {
          this.showCacheSnack($r('app.string.snack_cache_cleared', cleared));
        });
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.dialog_clear_cache_title'),
      message: $r('app.string.dialog_clear_cache_message'),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: confirmButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  /** 清理结果提示。 */
  private showCacheSnack(message: ResourceStr): void {
    const bar: HdsSnackBar = new HdsSnackBar(this.getUIContext());
    const icon: SnackBarIconOptions = { icon: $r('sys.symbol.checkmark_circle') };
    const text: SnackBarMessageOptions = { title: message };
    const operation: SnackBarOperationOptions = {
      operationType: SnackBarOperationType.CLOSE_BUTTON_ONLY,
      closeButtonAccessibilityText: $r('app.string.snack_dismiss')
    };
    const style: SnackBarStyleOptions = { duration: 3000 };
    bar.show(icon, text, operation, style);
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

  @Builder
  SectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize($r('app.float.font_size_section'))
      .fontColor($r('app.color.hm_text_secondary'))
      .margin({ top: $r('app.float.space_xl'), bottom: $r('app.float.space_s'), left: $r('app.float.space_xs') })
  }

  @Builder
  NavRow(icon: Resource, title: ResourceStr, page: string) {
    Row() {
      SettingLeading(icon, title)
      Blank()
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([$r('app.color.hm_text_secondary')])
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    .onClick(() => {
      this.navPathStack.pushPath(new NavPathInfo(page, ''));
    })
  }

  @Builder
  MaterialCard() {
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
      Divider().color($r('app.color.hm_divider'))
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
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        // 透明标题栏占位：首屏顶部预留「状态栏 + 标题栏」高度，滚动时随内容上移，内容即可穿过标题栏下方。
        Row().width('100%').height(safeArea.contentTopInsetVp)

        this.SectionTitle($r('app.string.section_appearance'))
        this.MaterialCard()

        Text(settingsViewModel.globalImmersive
          ? $r('app.string.aux_global_immersive_on')
          : $r('app.string.aux_global_immersive_off'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })

        this.SectionTitle($r('app.string.section_branding'))
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
          .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })

        this.SectionTitle($r('app.string.section_language'))
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
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        this.SectionTitle($r('app.string.section_navigation'))
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
          this.NavRow($r('sys.symbol.lightbulb'), $r('app.string.row_effect_preview'), RouterConstants.PAGE_EFFECT)
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        this.SectionTitle($r('app.string.section_reading'))
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

        this.SectionTitle($r('app.string.section_list'))
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

        this.SectionTitle($r('app.string.section_feed'))
        Column() {
          OptionSelectRow({
            icon: $r('sys.symbol.arrow_clockwise'),
            title: $r('app.string.row_auto_refresh'),
            choice: AUTO_REFRESH_OPTIONS,
            field: SettingField.AUTO_REFRESH,
            onPick: (id: string) => {
              settingsViewModel.setAutoRefresh(id, this.hostContext());
            }
          })
          Divider().color($r('app.color.hm_divider'))
          Row() {
            SettingLeading($r('sys.symbol.arrow_clockwise'), $r('app.string.row_refresh_now'))
            Blank()
            Text(feedViewModel.lastUpdated > 0
              ? $r('app.string.home_last_sync', DateUtil.clock(feedViewModel.lastUpdated))
              : $r('app.string.home_never_synced'))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
          }
          .width('100%')
          .height($r('app.float.row_height'))
          .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
          .onClick(() => {
            this.refreshNow();
          })
          Divider().color($r('app.color.hm_divider'))
          Row() {
            SettingLeading($r('sys.symbol.paintpalette'), $r('app.string.hl_library_title'))
            Blank()
            Text($r('app.string.hl_panel_title', this.highlightCount))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor([$r('app.color.hm_text_secondary')])
              .padding({ left: $r('app.float.space_xs') })
          }
          .width('100%')
          .height($r('app.float.row_height'))
          .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
          .onClick(() => {
            this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_HIGHLIGHTS, ''));
          })
          Divider().color($r('app.color.hm_divider'))
          OptionSelectRow({
            icon: $r('sys.symbol.externaldrive'),
            title: $r('app.string.row_archive_rule'),
            choice: ARCHIVE_OPTIONS,
            field: SettingField.ARCHIVE_RULE,
            onPick: (id: string) => {
              settingsViewModel.setArchiveRule(id);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          SwitchSettingRow({
            icon: $r('sys.symbol.bell'),
            title: $r('app.string.row_notify_new'),
            field: SettingField.NOTIFY_NEW,
            onToggle: (value: boolean) => {
              this.toggleNotify(value);
            }
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        this.SectionTitle($r('app.string.section_system'))
        Column() {
          SwitchSettingRow({
            icon: $r('sys.symbol.hand_raised_hexagon'),
            title: $r('app.string.row_grip'),
            field: SettingField.GRIP,
            onToggle: (value: boolean) => {
              settingsViewModel.setGripEnabled(value);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          SwitchSettingRow({
            icon: $r('sys.symbol.eye_slash'),
            title: $r('app.string.row_antipeep'),
            field: SettingField.ANTI_PEEP,
            onToggle: (value: boolean) => {
              settingsViewModel.setAntiPeepEnabled(value, this.hostContext());
            }
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        this.SectionTitle($r('app.string.section_storage'))
        Column() {
          Row() {
            SettingLeading($r('sys.symbol.externaldrive'), $r('app.string.row_reader_cache'))
            Blank()
            Text(this.cacheSummary())
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize($r('app.float.icon_size_small'))
              .fontColor([$r('app.color.hm_text_secondary')])
              .padding({ left: $r('app.float.space_xs') })
          }
          .width('100%')
          .height($r('app.float.row_height'))
          .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
          .onClick(() => {
            this.confirmClearCache();
          })

          Text($r('app.string.aux_reader_cache'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding({
              left: $r('app.float.space_m'),
              right: $r('app.float.space_m'),
              bottom: $r('app.float.space_m')
            })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))
        .alignItems(HorizontalAlign.Start)

        if (!antiPeep.supported) {
          Text($r('app.string.aux_antipeep_unsupported'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })
        }

        // 底部预留：避让悬浮页签栏与系统导航条。
        Blank().height(safeArea.contentBottomInsetVp)
      }
      .width('100%')
      // 首屏位置由 HDS 的标题栏安全区自动排定，这里只留左右间距。
      .padding({
        left: $r('app.float.space_l'),
        right: $r('app.float.space_l')
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    // 内容穿透标题栏：超出滚动区范围的部分不裁剪。
    .clip(false)
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
