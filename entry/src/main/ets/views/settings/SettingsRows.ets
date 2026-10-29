/*
 * SettingsRows.ets — 设置页（主页 + 各二级页）共用的行与小节标题（纯状态管理 V2）。
 *
 * 为什么行做成 @ComponentV2 而不是多参 @Builder：ArkUI 规定 @Builder 传入两个及以上参数时
 * 不触发动态刷新（官方文档「@Builder 参数传递规则」）。各行自己在 build() 里读 appSettings 的
 * @Trace 字段，选完值 / 拨完开关才会立刻反映到行文案上。
 *
 * 导航与动作都通过 @Event 上报，组件本身不持有 NavPathStack，便于在主页和二级页复用。
 */

import { appSettings } from '../../model/AppSettings';
import { ChoiceOption, ChoiceSet, THEME_OPTIONS } from '../../model/SettingsOptions';
import { MaterialController } from '../../service/MaterialController';

/** 设置页每一行绑定到 appSettings 的哪个字段。 */
export enum SettingField {
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
  READER_INDENT = 'readerIndent',
  READER_PREFETCH = 'readerPrefetch',
  READER_KEEP_ON = 'readerKeepScreenOn',
  NOTIFY_NEW = 'notifyNew',
  DEDUPE = 'dedupe'
}

/** 行首图标 + 标题。纯静态内容，不随状态变化。 */
@ComponentV2
export struct SettingIconTitle {
  @Param icon: Resource = $r('sys.symbol.house');
  @Param title: ResourceStr = '';

  build() {
    Row({ space: $r('app.float.space_m') }) {
      SymbolGlyph(this.icon)
        .fontSize($r('app.float.icon_size'))
        .fontColor([$r('app.color.hm_brand')])
      // 多语言长文案（德语尤其长）：标题让出空间并省略，避免把右侧取值 / 开关 / 箭头挤出屏幕。
      Text(this.title)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
  }
}

/** 小节标题（卡片上方的小字）。 */
@ComponentV2
export struct SettingsSectionTitle {
  @Param title: ResourceStr = '';

  build() {
    Text(this.title)
      .fontSize($r('app.float.font_size_section'))
      .fontColor($r('app.color.hm_text_secondary'))
      .width('100%')
      .margin({ top: $r('app.float.space_xl'), bottom: $r('app.float.space_s'), left: $r('app.float.space_xs') })
  }
}

/** 下拉选项行：自己读 appSettings 的当前值并弹 Menu。 */
@ComponentV2
export struct OptionSelectRow {
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
      case SettingField.READER_INDENT:
        return appSettings.readerIndent;
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
      .backgroundColor(selected ? $r('app.color.hm_menu_item_selected') : $r('app.color.hm_page_transparent'))
      // 与菜单容器圆角一致，避免内外圆角不一致。
      .borderRadius($r('app.float.radius_card'))

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
    Row({ space: $r('app.float.space_s') }) {
      Row() {
        SettingIconTitle({ icon: this.icon, title: this.title })
      }
      .layoutWeight(1)
      // 当前值做成「胶囊底 + 实心倒三角」的取值控件（与系统设置页一致）。
      // 长文案（如德语「Systemeinstellung folgen」）限宽并省略，避免把左侧标题挤没。
      Row({ space: $r('app.float.space_xs') }) {
        Text(this.choice.labelOf(this.currentId()))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
          .fontSize($r('app.float.icon_size_tiny'))
          .fontColor([$r('app.color.hm_text_primary')])
          .flexShrink(0)
      }
      .constraintSize({ maxWidth: '58%' })
      .flexShrink(0)
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
export struct SwitchSettingRow {
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
      case SettingField.READER_PREFETCH:
        return appSettings.prefetchReader;
      case SettingField.DEDUPE:
        return appSettings.dedupeEnabled;
      default:
        return appSettings.immersiveOn;
    }
  }

  build() {
    Row() {
      Row({ space: $r('app.float.space_s') }) {
        Row() {
          SettingIconTitle({ icon: this.icon, title: this.title })
        }
        .layoutWeight(1)
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

/** 跳转行：右侧可选状态文案 + 右箭头。 */
@ComponentV2
export struct NavSettingRow {
  @Param icon: Resource = $r('sys.symbol.house');
  @Param title: ResourceStr = '';
  @Param detail: ResourceStr = '';
  @Event onOpen: () => void = () => {};

  build() {
    Row() {
      Row() {
        SettingIconTitle({ icon: this.icon, title: this.title })
      }
      .layoutWeight(1)
      if (this.detail !== '') {
        Text(this.detail)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '40%' })
      }
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([$r('app.color.hm_text_secondary')])
        .padding({ left: $r('app.float.space_xs') })
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    .onClick(() => {
      this.onOpen();
    })
  }
}

/** 动作行：执行一个就地操作（如清理缓存），右侧可选状态文案 + 下箭头。 */
@ComponentV2
export struct ActionSettingRow {
  @Param icon: Resource = $r('sys.symbol.house');
  @Param title: ResourceStr = '';
  @Param detail: ResourceStr = '';
  @Event onAction: () => void = () => {};

  build() {
    Row() {
      Row() {
        SettingIconTitle({ icon: this.icon, title: this.title })
      }
      .layoutWeight(1)
      if (this.detail !== '') {
        Text(this.detail)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '40%' })
      }
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([$r('app.color.hm_text_secondary')])
        .padding({ left: $r('app.float.space_xs') })
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    .onClick(() => {
      this.onAction();
    })
  }
}
