/*
 * SubscriptionsView.ets — 订阅源管理（订阅源页签内容，纯展示 + 事件上报）。
 *
 * 结构：整页只有一个 List —— 页头（顶部占位 + 资料库快捷入口 + 订阅源小节头）作为第 0 项，
 * 随内容一起滚走；下面是「分组头 + 订阅源行」组成的连续卡片。
 *
 * 视觉约定：
 *   - 资料库改为一卡四格的快捷入口，把首屏让给订阅源；
 *   - 同一分组共用一张卡：组头负责上圆角，组内最后一行负责下圆角，行间只留 1vp 分割线；
 *   - 组头显示整组未读数、离线开关与折叠箭头；多选时统一展开并隐藏折叠 / 离线控件。
 *
 * 添加订阅源只保留 MiniBar 一处入口；OPML 导入 / 导出已移到「订阅与通知」设置页；
 * 订阅源行支持就地改名 / 分组 / 地址、长按拖拽排序、批量管理（移动分组 / 删除）。
 */

import { LengthMetrics } from '@kit.ArkUI';
import { FeedListItem, FeedSource } from '../model/Feed';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { FeedErrorText } from '../common/utils/FeedErrorText';
import { safeArea } from '../service/SafeAreaController';
import { CommonConstants } from '../common/constants/CommonConstants';
import { Toast } from '@rss/toast-kit';
import { RouterConstants } from '../common/constants/RouterConstants';
import { MaterialController } from '../service/MaterialController';
import { appSettings } from '../model/AppSettings';
import { tagViewModel } from '../viewmodel/TagViewModel';
import { smartFolderViewModel } from '../viewmodel/SmartFolderViewModel';
import { ruleViewModel } from '../viewmodel/RuleViewModel';
import { ListDensityMetrics } from '../common/constants/SettingsConstants';
import { AppMenu } from '../common/components/AppMenu';
import { MenuItemSpec, MenuSpec } from '../common/components/MenuSpec';
import { themePalette } from '../model/ThemePalette';
import { LibraryQuickAccess } from './LibraryTiles';
import { SubscriptionsGroupHeader } from './SubscriptionsGroupHeader';
import { FeedIcon } from './FeedIcon';
import { SubscriptionCountBadge, SubscriptionFeedStatus } from './SubscriptionFeedStatus';

/**
 * 列表头部固定合并成 1 个 ListItem。
 * 拖拽回调拿到的 itemIndex 是「含头部」的列表下标，换算成订阅行下标时要减掉它。
 */
const HEADER_ROWS: number = 1;

@ComponentV2
export struct SubscriptionsView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  /** 就地重命名：正在编辑的订阅源 id 与草稿名。 */
  @Local editingId: string = '';
  @Local draftTitle: string = '';
  /** 就地编辑分组：正在编辑分组的订阅源 id 与草稿分组名。 */
  @Local groupEditId: string = '';
  @Local draftGroup: string = '';
  /** 就地编辑订阅地址：正在编辑的订阅源 id 与草稿地址。 */
  @Local urlEditId: string = '';
  @Local draftUrl: string = '';
  /** 多选批量管理：是否处于选择态与选中的订阅源 id。 */
  @Local selecting: boolean = false;
  @Local selectedIds: string[] = [];

  /**
   * 进入页签 / 回到本页时刷新三个入口的计数。
   * 计数本身读的是 @ObservedV2 单例的 @Trace 数组长度，任何打标 / 增删操作后都会自动更新；
   * 这里再主动 load 一次，冷启动首个渲染也有数据。
   */
  aboutToAppear(): void {
    this.refreshCounts();
  }

  /** 刷新标签 / 智能文件夹 / 规则计数（入口行可见时调用）。 */
  refreshCounts(): void {
    tagViewModel.load();
    smartFolderViewModel.load();
    ruleViewModel.load();
  }

  /** 页头：顶部占位 + 资料库快捷入口 + 订阅源小节标题（作为 List 第 0 项，随内容滚走）。 */
  @Builder
  Header() {
    Column() {
      // 透明标题栏占位：放进滚动内容里，内容才能穿过标题栏（HDS 材质渐显随之生效）。
      Row().width('100%').height(safeArea.contentTopInsetVp)

      Text($r('app.string.subs_library_title'))
        .fontSize($r('app.float.font_size_section'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
        .margin({
          top: $r('app.float.space_m'),
          bottom: $r('app.float.space_s'),
          left: $r('app.float.space_xs')
        })

      LibraryQuickAccess({
        onOpen: (route: string) => {
          this.navPathStack.pushPath(new NavPathInfo(route, ''));
        }
      })

      this.FeedsSectionHeader()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 订阅源小节标题：左侧数量 / 未读汇总，右侧「选择」入口。 */
  @Builder
  FeedsSectionHeader() {
    Row({ space: $r('app.float.space_s') }) {
      Text($r('app.string.tab_subs'))
        .fontSize($r('app.float.font_size_section'))
        .fontColor($r('app.color.hm_text_secondary'))
        .flexShrink(0)

      if (feedViewModel.feeds.length > 0) {
        Row({ space: $r('app.float.space_xs') }) {
          Text($r('app.string.home_feed_count', feedViewModel.feeds.length))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (feedViewModel.unreadTotal > 0) {
            Text('·')
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .flexShrink(0)
            Text($r('app.string.home_unread_count', feedViewModel.unreadTotal))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .maxLines(1)
              .flexShrink(0)
          }
        }
        .layoutWeight(1)
        .clip(true)
      } else {
        Blank()
      }

      if (feedViewModel.feeds.length > 0 && !this.selecting) {
        Button($r('app.string.subs_bulk_enter'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(themePalette.accent())
          .flexShrink(0)
          .onClick(() => {
            this.enterSelect('');
          })
      }
    }
    .width('100%')
    .padding({ left: $r('app.float.space_xs'), right: $r('app.float.space_xs') })
    .margin({
      top: $r('app.float.space_l'),
      bottom: $r('app.float.space_xs')
    })
  }

  /** 是否处于就地编辑（重命名 / 分组 / 地址）。 */
  private isEditing(feedId: string): boolean {
    return this.editingId === feedId || this.groupEditId === feedId || this.urlEditId === feedId;
  }

  private isSelected(feedId: string): boolean {
    return this.selectedIds.indexOf(feedId) >= 0;
  }

  /** 进入选择态。feedId 为空串时从「选择」入口进入，先不选任何行。 */
  private enterSelect(feedId: string): void {
    // 折叠行里的订阅源无法被选中：进入多选先全部展开。
    feedViewModel.expandAllGroups();
    this.selecting = true;
    this.selectedIds = feedId.length > 0 ? [feedId] : [];
  }

  private toggleSelect(feedId: string): void {
    if (!this.selecting) {
      return;
    }
    if (this.isSelected(feedId)) {
      this.selectedIds = this.selectedIds.filter((id: string) => id !== feedId);
    } else {
      this.selectedIds = this.selectedIds.concat([feedId]);
    }
  }

  private exitSelect(): void {
    this.selecting = false;
    this.selectedIds = [];
  }

  /** 批量删除前确认。 */
  private confirmRemoveMany(): void {
    const count: number = this.selectedIds.length;
    if (count === 0) {
      return;
    }
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const removeButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.subs_remove'),
      fontColor: $r('app.color.hm_danger'),
      action: () => {
        feedViewModel.removeFeeds(this.selectedIds);
        this.exitSelect();
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.subs_remove_confirm_title'),
      message: $r('app.string.subs_bulk_remove_message', count),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: removeButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  /** 批量移动分组的菜单（统一交给 AppMenu 渲染，规格现算）。 */
  @Builder
  BulkGroupMenu() {
    AppMenu(this.bulkGroupMenuSpec());
  }

  /**
   * 批量移动分组的菜单规格：跳过所有选中源都已属于的分组，其他项顺序不变。
   * 分组项 id 加 'group:' 前缀 —— 菜单内 id 必须唯一，动态分组名可能与固定项撞车。
   */
  private bulkGroupMenuSpec(): MenuSpec {
    let currentGroup: string | undefined = undefined;
    for (let i = 0; i < this.selectedIds.length; i += 1) {
      const id: string = this.selectedIds[i];
      const feed: FeedSource | undefined = feedViewModel.feeds.find((item: FeedSource) => item.id === id);
      if (feed === undefined || (currentGroup !== undefined && currentGroup !== feed.group)) {
        currentGroup = undefined;
        break;
      }
      currentGroup = feed.group;
    }

    const items: MenuItemSpec[] = [];
    if (currentGroup !== '') {
      items.push(new MenuItemSpec('group_ungrouped', $r('app.string.group_ungrouped'), (): void => {
        feedViewModel.setFeedGroupMany(this.selectedIds, '');
        this.exitSelect();
      }));
    }
    const names: string[] = feedViewModel.groupNames();
    for (let i = 0; i < names.length; i += 1) {
      const name: string = names[i];
      if (name === currentGroup) {
        continue;
      }
      items.push(new MenuItemSpec('group:' + name, name, (): void => {
        feedViewModel.setFeedGroupMany(this.selectedIds, name);
        this.exitSelect();
      }));
    }
    return MenuSpec.fromItems(items);
  }

  /** 没有可移动的目标分组时，不弹出空菜单。 */
  private canMoveSelectedGroup(): boolean {
    return this.selectedIds.length > 0 && this.bulkGroupMenuSpec().sections[0].items.length > 0;
  }

  /** 多选态动作条与页签栏之间的底边距。 */
  private selectBarBottom(): number {
    return safeArea.bottomInsetVp + CommonConstants.TAB_BAR_HEIGHT_VP + CommonConstants.SELECT_BAR_GAP_VP;
  }

  /**
   * 多选态动作条：悬浮在悬浮页签栏上方。
   * 用图标而不是文字按钮：德 / 法语的「移动到分组」会把一行字撑破。
   */
  @Builder
  SelectBar() {
    Column() {
      Row({ space: $r('app.float.space_xs') }) {
        Text($r('app.string.subs_bulk_selected', this.selectedIds.length))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([themePalette.accent()])
          .padding($r('app.float.space_s'))
          .opacity(this.canMoveSelectedGroup() ? 1 : 0.4)
          .accessibilityText($r('app.string.subs_bulk_move'))
          .enabled(this.canMoveSelectedGroup())
          // 动作条贴着屏幕底部，菜单必须向上弹，否则会被屏底裁掉。
          .bindMenu(this.BulkGroupMenu(),
            MaterialController.menuOptions({ placement: Placement.TopRight }, appSettings.immersiveOn))
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([$r('app.color.hm_danger')])
          .padding($r('app.float.space_s'))
          .opacity(this.selectedIds.length > 0 ? 1 : 0.4)
          .accessibilityText($r('app.string.subs_bulk_remove'))
          .enabled(this.selectedIds.length > 0)
          .onClick(() => {
            this.confirmRemoveMany();
          })
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([themePalette.accent()])
          .padding($r('app.float.space_s'))
          .accessibilityText($r('app.string.dialog_cancel'))
          .onClick(() => {
            this.exitSelect();
          })
      }
      .width('100%')
      .height(CommonConstants.SELECT_BAR_HEIGHT_VP)
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_s') })
      .backgroundColor($r('app.color.hm_card_background'))
      .borderRadius($r('app.float.radius_card'))
    }
    .width('100%')
    .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    .margin({ bottom: this.selectBarBottom() })
  }

  /** 保存编辑后的订阅地址：保留原标题与分组，失败时提示。 */
  private async saveUrl(feedId: string): Promise<void> {
    const ok: boolean = await feedViewModel.replaceFeedUrl(feedId, this.draftUrl);
    this.urlEditId = '';
    if (!ok) {
      Toast.show(FeedErrorText.of(feedViewModel.errorCode));
    }
  }

  /** 删除前确认：避免误触把订阅源和它的文章一起删掉。 */
  private confirmRemove(feed: FeedSource): void {
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const removeButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.subs_remove'),
      fontColor: $r('app.color.hm_danger'),
      action: () => {
        feedViewModel.removeFeed(feed.id);
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.subs_remove_confirm_title'),
      message: $r('app.string.subs_remove_confirm_message', feed.title),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: removeButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  /** 行标题文案（分组头用分组名，订阅源行用源标题）。 */
  private rowLabel(row: FeedListItem): ResourceStr {
    if (row.isGroup) {
      return row.groupName.length > 0 ? row.groupName : $r('app.string.group_ungrouped');
    }
    return row.feed.title;
  }

  /** 长按拖拽时跟随手指的预览。 */
  @Builder
  DragPreview(row: FeedListItem) {
    Row({ space: $r('app.float.space_s') }) {
      SymbolGlyph(row.isGroup ? $r('sys.symbol.folder') : $r('sys.symbol.folder_fill'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([themePalette.accent()])
      Text(this.rowLabel(row))
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  /** 头部行不可拖拽：给一个 0 尺寸预览，落点也会被忽略。 */
  @Builder
  EmptyDragPreview() {
    Row().width(0).height(0)
  }

  /** 行内溢出菜单：设置 / 重命名 / 改地址 / 分组 / 排序 / 批量 / 删除（AppMenu 渲染）。 */
  @Builder
  FeedMenu(feed: FeedSource) {
    AppMenu(this.feedMenuSpec(feed));
  }

  /**
   * 行内溢出菜单的规格：跳过当前分组的无效移动项，其他条目顺序不变。
   * 分组项 id 加 'group:' 前缀保证菜单内唯一；末项删除标危险色。
   */
  private feedMenuSpec(feed: FeedSource): MenuSpec {
    const items: MenuItemSpec[] = [
      new MenuItemSpec('feed_settings', $r('app.string.feed_settings_entry'), (): void => {
        feedViewModel.openFeedSettings(feed);
        this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_FEED_SETTINGS, ''));
      }),
      new MenuItemSpec('rename', $r('app.string.subs_rename'), (): void => {
        this.editingId = feed.id;
        this.draftTitle = feed.title;
      }),
      new MenuItemSpec('edit_url', $r('app.string.subs_edit_url'), (): void => {
        this.urlEditId = feed.id;
        this.draftUrl = feed.url;
      })
    ];
    if (feed.group.length > 0) {
      items.push(new MenuItemSpec('group_clear', $r('app.string.group_clear'), (): void => {
        feedViewModel.setFeedGroup(feed.id, '');
      }));
    }
    const names: string[] = feedViewModel.groupNames();
    for (let i = 0; i < names.length; i += 1) {
      const name: string = names[i];
      if (name === feed.group) {
        continue;
      }
      items.push(new MenuItemSpec('group:' + name, $r('app.string.group_move_to', name), (): void => {
        feedViewModel.setFeedGroup(feed.id, name);
      }));
    }
    items.push(new MenuItemSpec('group_new', $r('app.string.group_new'), (): void => {
      this.groupEditId = feed.id;
      this.draftGroup = feed.group;
    }));
    items.push(new MenuItemSpec('move_up', $r('app.string.feed_move_up'), (): void => {
      feedViewModel.moveFeed(feed.id, -1);
    }));
    items.push(new MenuItemSpec('move_down', $r('app.string.feed_move_down'), (): void => {
      feedViewModel.moveFeed(feed.id, 1);
    }));
    items.push(new MenuItemSpec('bulk_select', $r('app.string.subs_bulk_enter'), (): void => {
      this.enterSelect(feed.id);
    }));
    items.push(new MenuItemSpec('remove', $r('app.string.subs_remove'), (): void => {
      this.confirmRemove(feed);
    }).markDanger());
    return MenuSpec.fromItems(items);
  }

  /** 订阅行卡片圆角：只有组内最后一行圆下面两角，其余行与组头 / 上一行相接。 */
  private feedRowCorners(feed: FeedSource): BorderRadiuses {
    const radius: Resource = $r('app.float.radius_card');
    const last: boolean = this.lastFeedIds.has(feed.id);
    return {
      topLeft: 0,
      topRight: 0,
      bottomLeft: last ? radius : 0,
      bottomRight: last ? radius : 0
    };
  }

  @Builder
  FeedRow(feed: FeedSource) {
    Column() {
      Divider()
        .strokeWidth(1)
        .color($r('app.color.hm_divider'))
        .margin({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })

      Row({ space: $r('app.float.space_s') }) {
        if (this.selecting) {
          // 只用 onClick 更新选中集合：onChange 会在「选中态被回写到 Checkbox」时再触发一次，
          // 和行点击互相抵消（点整行选不中，几秒后又被自己取消）。
          Checkbox({ name: feed.id })
            .select(this.isSelected(feed.id))
            .selectedColor(themePalette.fill())
            .onClick(() => {
              this.toggleSelect(feed.id);
            })
        }

        // 信息区点击 = 进入该源的单源视图（返回阅读页只看这个订阅源的文章）。
        Row({ space: $r('app.float.space_s') }) {
          FeedIcon({ feed: feed })

          Column({ space: $r('app.float.space_xxs') }) {
            if (this.groupEditId === feed.id) {
              Row({ space: $r('app.float.space_s') }) {
                TextInput({ text: this.draftGroup, placeholder: $r('app.string.group_hint') })
                  .type(InputType.Normal)
                  .fontSize($r('app.float.font_size_body'))
                  .layoutWeight(1)
                  .onChange((value: string) => {
                    this.draftGroup = value;
                  })
                Button($r('app.string.dialog_save'))
                  .buttonStyle(ButtonStyleMode.NORMAL)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.hm_on_brand'))
                  .backgroundColor(themePalette.fill())
                  .onClick(() => {
                    feedViewModel.setFeedGroup(feed.id, this.draftGroup);
                    this.groupEditId = '';
                  })
              }
              .width('100%')
            } else if (this.editingId === feed.id) {
              Row({ space: $r('app.float.space_s') }) {
                TextInput({ text: this.draftTitle, placeholder: $r('app.string.subs_rename_hint') })
                  .type(InputType.Normal)
                  .fontSize($r('app.float.font_size_body'))
                  .layoutWeight(1)
                  .onChange((value: string) => {
                    this.draftTitle = value;
                  })
                Button($r('app.string.dialog_save'))
                  .buttonStyle(ButtonStyleMode.NORMAL)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.hm_on_brand'))
                  .backgroundColor(themePalette.fill())
                  .onClick(() => {
                    feedViewModel.renameFeed(feed.id, this.draftTitle);
                    this.editingId = '';
                  })
              }
              .width('100%')
            } else if (this.urlEditId === feed.id) {
              Row({ space: $r('app.float.space_s') }) {
                TextInput({ text: this.draftUrl, placeholder: $r('app.string.subs_edit_url_hint') })
                  .type(InputType.Normal)
                  .fontSize($r('app.float.font_size_body'))
                  .layoutWeight(1)
                  .onChange((value: string) => {
                    this.draftUrl = value;
                  })
                Button($r('app.string.dialog_save'))
                  .buttonStyle(ButtonStyleMode.NORMAL)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.hm_on_brand'))
                  .backgroundColor(themePalette.fill())
                  .onClick(() => {
                    this.saveUrl(feed.id);
                  })
              }
              .width('100%')
            } else {
              Row({ space: $r('app.float.space_s') }) {
                Text(feed.title)
                  .fontSize($r('app.float.font_size_body'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.hm_text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                SubscriptionCountBadge({ feed: feed })
              }
              .width('100%')
            }

            SubscriptionFeedStatus({ feed: feed })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .onClick(() => {
          // 选择态：点信息区即勾选 / 取消勾选，不进入单源视图。
          if (this.selecting) {
            this.toggleSelect(feed.id);
            return;
          }
          if (!this.isEditing(feed.id)) {
            feedViewModel.openFeed(feed);
            this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_FEED_ARTICLES, ''));
          }
        })

        if (this.selecting) {
          // 选择态由左侧勾选框承担交互，不再显示溢出菜单。
        } else if (this.isEditing(feed.id)) {
          Button($r('app.string.dialog_cancel'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .onClick(() => {
              this.editingId = '';
              this.groupEditId = '';
              this.urlEditId = '';
            })
        } else {
          Row() {
            SymbolGlyph($r('sys.symbol.line_3_horizontal'))
              .fontSize($r('app.float.icon_size'))
              .fontColor([themePalette.accent()])
          }
          .width(40)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .accessibilityText($r('app.string.action_more'))
          .bindMenu(this.FeedMenu(feed),
            MaterialController.menuOptions({
              placement: Placement.TopRight,
              maxHeight: LengthMetrics.resource($r('app.float.feed_menu_max_height'))
            }, appSettings.immersiveOn))
        }
      }
      .width('100%')
      .padding({
        left: $r('app.float.space_m'),
        right: $r('app.float.space_xs'),
        top: ListDensityMetrics.padding(appSettings.listDensity),
        bottom: ListDensityMetrics.padding(appSettings.listDensity)
      })
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius(this.feedRowCorners(feed))
  }

  /** 空态：图标 + 说明 + 下一步动作。 */
  @Builder
  EmptyState() {
    Column({ space: $r('app.float.space_s') }) {
      // 用「空文件夹」而不是 rays（放射状图标在小尺寸下容易被误认为加载中）。
      SymbolGlyph($r('sys.symbol.folder'))
        .fontSize($r('app.float.hero_icon_size'))
        .fontColor([$r('app.color.hm_text_secondary')])
      Text($r('app.string.subs_empty'))
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
      Text($r('app.string.subs_empty_hint'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .textAlign(TextAlign.Center)
      Button($r('app.string.subs_discover_action'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_on_brand'))
        .backgroundColor(themePalette.fill())
        .margin({ top: $r('app.float.space_s') })
        .onClick(() => {
          this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_DISCOVER, ''));
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_l'),
      right: $r('app.float.space_l'),
      top: $r('app.float.space_2xl'),
      bottom: $r('app.float.space_2xl')
    })
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 行键值：把「是否会改变行的结构 / 模式」编码进去。
   * 折叠态、组内末行、多选态、编辑态都会改变布局，键值变化可让 ForEach 重建该行；
   * 未读数故意不放进键值，避免后台同步时整行重建（徽标由 @Trace 自行刷新）。
   */
  private rowKey(row: FeedListItem): string {
    if (row.isGroup) {
      const collapsed: string = feedViewModel.isGroupCollapsed(row.groupName) ? 'c' : 'e';
      return 'g:' + row.groupName + ':' + collapsed;
    }
    const last: string = this.lastFeedIds.has(row.feed.id) ? 'l' : 'm';
    const select: string = this.selecting ? 's' : 'n';
    const edit: string = this.isEditing(row.feed.id) ? 'e' : 'n';
    return 'f:' + row.feed.id + ':' + last + ':' + select + ':' + edit;
  }

  /** 只在订阅或折叠状态变化时重建分组行，避免未读数刷新重复分桶。 */
  @Computed
  get displayRows(): FeedListItem[] {
    return feedViewModel.displayRows();
  }

  /** 每组末行只扫描一次；行键值与圆角共享结果。 */
  @Computed
  get lastFeedIds(): Set<string> {
    const byGroup: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < feedViewModel.feeds.length; i += 1) {
      const feed: FeedSource = feedViewModel.feeds[i];
      byGroup.set(feed.group, feed.id);
    }
    return new Set<string>(byGroup.values());
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        List({ scroller: this.scroller }) {
          // 第 0 项：整块页头（占位 + 资料库快捷入口 + 订阅源小节标题），随滚动离开。
          ListItem() {
            this.Header()
          }

          if (feedViewModel.feeds.length === 0) {
            ListItem() {
              this.EmptyState()
            }
          } else {
            ForEach(this.displayRows, (row: FeedListItem) => {
              ListItem() {
                if (row.isGroup) {
                  SubscriptionsGroupHeader({
                    feeds: feedViewModel.feeds,
                    groupName: row.groupName,
                    collapsed: feedViewModel.isGroupCollapsed(row.groupName),
                    selecting: this.selecting,
                    onToggleCollapse: () => {
                      feedViewModel.toggleGroupCollapsed(row.groupName);
                    }
                  })
                } else {
                  this.FeedRow(row.feed)
                }
              }
            }, (row: FeedListItem) => this.rowKey(row))

          }
        }
        .width('100%')
        .layoutWeight(1)
        // 列表延伸到悬浮栏后方；末尾为页签栏与多选操作条留出可滚动距离。
        .contentEndOffset(safeArea.contentBottomInsetVp + (this.selecting
          ? CommonConstants.SELECT_BAR_HEIGHT_VP + CommonConstants.SELECT_BAR_GAP_VP : 0))
        .padding({
          left: $r('app.float.space_l'),
          right: $r('app.float.space_l')
        })
        .scrollBar(BarState.Off)
        // 长按拖拽排序：拖订阅源行 → 单条移动（含跨组）；拖分组头 → 整组换位。
        // 头部是第 0 项，行索引用 HEADER_ROWS 换算，否则会「拖 A 动 B」。
        .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
          const rowIndex: number = itemIndex - HEADER_ROWS;
          if (rowIndex < 0) {
            return this.EmptyDragPreview();
          }
          return this.DragPreview(feedViewModel.rowAt(rowIndex));
        })
        .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
          if (!isSuccess || itemIndex < HEADER_ROWS) {
            return;
          }
          const from: number = itemIndex - HEADER_ROWS;
          const to: number = Math.max(0, insertIndex - HEADER_ROWS);
          feedViewModel.reorderByDrag(from, to);
        })

      }
      .width('100%')
      .height('100%')

      if (this.selecting) {
        this.SelectBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
