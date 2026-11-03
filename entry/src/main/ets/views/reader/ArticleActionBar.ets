/*
 * ArticleActionBar.ets — 详情页底部悬浮操作栏（HdsTabs 悬浮页签栏承载）。
 *
 * 从 ArticleDetailView 拆出：这里只负责 8 个动作按钮与悬浮栏材质，
 * 具体做什么（切文 / 开面板 / 切模式 / 收藏 / 打标签）由详情页通过事件注入，
 * 溢出菜单的规格也由详情页在打开时现算（menuProvider），避免缓存过期。
 */

import { display } from '@kit.ArkUI';
import {
  HdsBarWidthRangeOptions,
  HdsTabs,
  HdsTabsController,
  HdsTabsFloatingStyle
} from '@kit.UIDesignKit';
import { MaterialController } from '../../service/MaterialController';
import { safeArea } from '../../service/SafeAreaController';
import { appSettings } from '../../model/AppSettings';
import { CommonConstants } from '../../common/constants/CommonConstants';
import { AppMenu } from '../../common/components/AppMenu';
import { MenuSpec } from '../../common/components/MenuSpec';

@ComponentV2
export struct ArticleActionBar {
  /** 上一篇 / 下一篇 / 下一条未读是否可用（决定图标颜色与可点）。 */
  @Param canPrev: boolean = false;
  @Param canNext: boolean = false;
  @Param canNextUnread: boolean = false;
  /** 当前是否已收藏 / 是否在网页原文模式（决定图标与无障碍文案）。 */
  @Param starred: boolean = false;
  @Param webMode: boolean = false;
  /** 主题强调色（hex 字符串，跟随主题色与深浅色变化）。 */
  @Param accent: string = '';
  /** 溢出菜单规格：打开时才调用，保证读到最新的离线 / 模式状态。 */
  @Param menuProvider: () => MenuSpec = (): MenuSpec => MenuSpec.fromItems([]);

  @Event onPrev: () => void = () => {
  };
  @Event onNext: () => void = () => {
  };
  @Event onNextUnread: () => void = () => {
  };
  @Event onFont: () => void = () => {
  };
  @Event onMode: () => void = () => {
  };
  @Event onStar: () => void = () => {
  };
  @Event onTag: () => void = () => {
  };

  private tabsController: HdsTabsController = new HdsTabsController();

  /**
   * 悬浮操作栏样式：与首页悬浮页签栏同一套（沉浸光感材质 + 智感握姿 + 底部避让）。
   * barWidth 三个断点必须显式锁成同一个值，否则系统按断点套默认宽度，背板会比内容窄。
   */
  private floatingStyle(): HdsTabsFloatingStyle {
    const width: number = this.barWidthVp();
    const widths: HdsBarWidthRangeOptions = {
      smallWidth: width,
      mediumWidth: width,
      largeWidth: width
    };
    return {
      barWidth: widths,
      adaptToHandedness: appSettings.gripEnabled,
      barBottomMargin: safeArea.bottomInsetVp,
      systemMaterialEffect: MaterialController.params(appSettings.materialType,
        appSettings.materialLevel, appSettings.immersiveOn)
    };
  }

  /** 栏宽：页宽 - 两侧留白 - 跟手侧移余量（余量由中间的 Blank 吃掉）。 */
  private barWidthVp(): number {
    try {
      const screenPx: number = display.getDefaultDisplaySync().width;
      return this.getUIContext().px2vp(screenPx)
        - 2 * CommonConstants.BAR_SIDE_MARGIN_VP
        - CommonConstants.BAR_HANDEDNESS_ROOM_VP;
    } catch (err) {
      return 0;
    }
  }

  /** 操作栏在页面里占的条带高度：悬浮页签栏高度 + 系统导航条避让。 */
  private stripHeight(): number {
    return safeArea.bottomInsetVp + CommonConstants.TAB_BAR_HEIGHT_VP;
  }

  @Builder
  BarContent() {
    Row({ space: $r('app.float.space_xs') }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([this.canPrev ? this.accent : $r('sys.color.font_tertiary')])
        .padding($r('app.float.space_xs'))
        .enabled(this.canPrev)
        .accessibilityText($r('app.string.article_prev'))
        .onClick(() => {
          this.onPrev();
        })

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([this.canNext ? this.accent : $r('sys.color.font_tertiary')])
        .padding($r('app.float.space_xs'))
        .enabled(this.canNext)
        .accessibilityText($r('app.string.article_next'))
        .onClick(() => {
          this.onNext();
        })

      SymbolGlyph($r('sys.symbol.envelope_badge_dot'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([this.canNextUnread ? this.accent : $r('sys.color.font_tertiary')])
        .padding($r('app.float.space_xs'))
        .enabled(this.canNextUnread)
        .accessibilityText($r('app.string.article_next_unread'))
        .onClick(() => {
          this.onNextUnread();
        })

      Blank()

      // 溢出菜单：内容在打开时由 menuProvider 现算，状态变化不会读到旧规格。
      SymbolGlyph($r('sys.symbol.more'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([this.accent])
        .padding($r('app.float.space_xs'))
        .accessibilityText($r('app.string.action_more'))
        .bindMenu(this.MoreMenu(), MaterialController.menuOptions({}, appSettings.immersiveOn))

      SymbolGlyph($r('sys.symbol.textformat'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([this.accent])
        .padding($r('app.float.space_xs'))
        .accessibilityText($r('app.string.row_reader_font'))
        .onClick(() => {
          this.onFont();
        })

      SymbolGlyph(this.webMode ? $r('sys.symbol.doc_text') : $r('sys.symbol.link'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([this.accent])
        .padding($r('app.float.space_xs'))
        .accessibilityText(this.webMode
          ? $r('app.string.article_mode_reader')
          : $r('app.string.article_mode_web'))
        .onClick(() => {
          this.onMode();
        })

      SymbolGlyph(this.starred ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([this.starred ? this.accent : $r('sys.color.font_primary')])
        .padding($r('app.float.space_xs'))
        .accessibilityText(this.starred ? $r('app.string.action_unstar') : $r('app.string.action_star'))
        .onClick(() => {
          this.onStar();
        })

      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([this.accent])
        .padding($r('app.float.space_xs'))
        .accessibilityText($r('app.string.tag_picker_title'))
        .onClick(() => {
          this.onTag();
        })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  MoreMenu() {
    AppMenu(this.menuProvider());
  }

  build() {
    HdsTabs({ controller: this.tabsController }) {
      // 唯一页签：内容为空 —— 只借「底部悬浮页签栏」这个沉浸光感生效区域承载操作栏。
      TabContent() {
      }
      .tabBar(this.BarContent())
    }
    .barPosition(BarPosition.End)
    .barOverlap(true)
    .vertical(false)
    // 禁用左右滑动切页签：页签栏只是容器。
    .scrollable(false)
    .barFloatingStyle(this.floatingStyle())
    .width('100%')
    .height(this.stripHeight())
  }
}
