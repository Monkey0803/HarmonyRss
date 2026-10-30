/*
 * SubscriptionsView.ets — 订阅源管理（订阅源页签内容，纯展示 + 事件上报）。
 *
 * 结构：整页只有一个 List —— 头部（顶部占位 + 添加卡 + 资料库卡 + 订阅源小节标题）作为第 0 项，
 * 随内容一起滚走，浏览订阅列表时可占满屏；下面是分组头 / 订阅源行。
 * 多选态的动作条悬浮在悬浮页签栏上方，不占内容高度。
 *
 * 顶部输入订阅地址并添加（添加前会先抓一次校验可用性）；支持 OPML 导入 / 导出（系统文档选择器）；
 * 订阅源行支持就地改名 / 分组 / 地址、长按拖拽排序、批量管理（移动分组 / 删除）。
 */

import { common } from '@kit.AbilityKit';
import { FeedListItem, FeedSource } from '../model/Feed';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { FeedErrorText } from '../common/utils/FeedErrorText';
import { safeArea } from '../service/SafeAreaController';
import { CommonConstants } from '../common/constants/CommonConstants';
import { ToastUtil } from '../common/utils/ToastUtil';
import { opmlService } from '../service/OpmlService';
import { OpmlEntry, parseOpml } from '../service/OpmlCodec';
import { RouterConstants } from '../common/constants/RouterConstants';
import { MaterialController } from '../service/MaterialController';
import { appSettings } from '../model/AppSettings';
import { AddFeedPanel } from './AddFeedPanel';
import { DateUtil } from '../common/utils/DateUtil';
import { UrlText } from '../common/utils/UrlText';
import { tagViewModel } from '../viewmodel/TagViewModel';
import { smartFolderViewModel } from '../viewmodel/SmartFolderViewModel';
import { ruleViewModel } from '../viewmodel/RuleViewModel';
import { NavSettingRow, SettingsSectionTitle } from './settings/SettingsRows';

/**
 * 列表头部固定合并成 1 个 ListItem。
 * 拖拽回调拿到的 itemIndex 是「含头部」的列表下标，换算成订阅行下标时要减掉它。
 */
const HEADER_ROWS: number = 1;

@ComponentV2
export struct SubscriptionsView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  @Local submitting: boolean = false;
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

  private hostContext(): common.UIAbilityContext {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    return context as common.UIAbilityContext;
  }

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

  /** 页头：顶部占位 + 添加卡 + 资料库卡 + 订阅源小节标题（作为 List 第 0 项，随内容滚走）。 */
  @Builder
  Header() {
    Column() {
      // 透明标题栏占位：放进滚动内容里，内容才能穿过标题栏（HDS 材质渐显随之生效）。
      Row().width('100%').height(safeArea.contentTopInsetVp)

      SettingsSectionTitle({ title: $r('app.string.home_add_feed_title') })
      this.AddCard()

      SettingsSectionTitle({ title: $r('app.string.subs_library_title') })
      this.LibraryCard()

      this.FeedsSectionHeader()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 添加卡：输入表单 + 发现入口 + OPML 导入 / 导出，全部收在一张卡里。 */
  @Builder
  AddCard() {
    Column() {
      // 复用添加面板：多行输入 + 预览确认 + 分组选择 + 剪贴板预填。
      // 标题上移成小节标题，面板内不再画 18 号标题（避免和页面标题形成双重标题）。
      AddFeedPanel({
        showTitle: false,
        onSubmitResult: () => {
        }
      })
      Divider().color($r('app.color.hm_divider'))
      // 发现：属于「怎么添加订阅」，从独立卡片归位到添加卡。
      NavSettingRow({
        icon: $r('sys.symbol.rays'),
        title: $r('app.string.discover_entry'),
        onOpen: () => {
          this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_DISCOVER, ''));
        }
      })
      Divider().color($r('app.color.hm_divider'))
      this.OpmlRow()
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    // 分割线 / 行按压底色跟着卡片圆角收边。
    .clip(true)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * OPML 导入 / 导出：都走系统文档选择器，无需存储权限。
   * 内边距与卡内其它元素同为 16（原来这里又套了一层，导致相对其它元素缩进 32、底部双倍留白）。
   */
  @Builder
  OpmlRow() {
    Row({ space: $r('app.float.space_s') }) {
      Button($r('app.string.subs_import_opml'))
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_brand'))
        .enabled(!this.submitting)
        .onClick(() => {
          this.importOpml();
        })
      Button($r('app.string.subs_export_opml'))
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_brand'))
        .enabled(!this.submitting)
        .onClick(() => {
          this.exportOpml();
        })
      Blank()
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_l'),
      right: $r('app.float.space_l'),
      top: $r('app.float.space_s'),
      bottom: $r('app.float.space_s')
    })
  }

  /** 资料库：标签 / 智能文件夹 / 规则。一张卡三行 + 分割线（与设置页同一套行与计数位）。 */
  @Builder
  LibraryCard() {
    Column() {
      NavSettingRow({
        icon: $r('sys.symbol.checkmark_circle'),
        title: $r('app.string.tag_title'),
        detail: String(tagViewModel.tags.length),
        onOpen: () => {
          this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_TAGS, ''));
        }
      })
      Divider().color($r('app.color.hm_divider'))
      NavSettingRow({
        icon: $r('sys.symbol.folder_fill'),
        title: $r('app.string.smart_folder_title'),
        detail: String(smartFolderViewModel.folders.length),
        onOpen: () => {
          this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_SMART_FOLDERS, ''));
        }
      })
      Divider().color($r('app.color.hm_divider'))
      NavSettingRow({
        icon: $r('sys.symbol.gearshape'),
        title: $r('app.string.rule_title'),
        detail: String(ruleViewModel.rules.length),
        onOpen: () => {
          this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_RULES, ''));
        }
      })
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .clip(true)
  }

  /** 订阅源小节标题：右侧「选择」入口，不必再从单行菜单里进入多选。 */
  @Builder
  FeedsSectionHeader() {
    Row({ space: $r('app.float.space_s') }) {
      Text($r('app.string.tab_subs'))
        .fontSize($r('app.float.font_size_section'))
        .fontColor($r('app.color.hm_text_secondary'))
      Blank()
      if (feedViewModel.feeds.length > 0 && !this.selecting) {
        Button($r('app.string.subs_bulk_enter'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .onClick(() => {
            this.enterSelect('');
          })
      }
    }
    .width('100%')
    .padding({ left: $r('app.float.space_xs'), right: $r('app.float.space_xs') })
    .margin({
      top: $r('app.float.space_xl'),
      bottom: $r('app.float.space_s')
    })
  }

  private toast(message: ResourceStr): void {
    ToastUtil.show(this.getUIContext(), message);
  }

  /** 导入 OPML：选文件 → 解析 → 去重入库并抓取。 */
  private async importOpml(): Promise<void> {
    this.submitting = true;
    const text: string = await opmlService.importFromFile(this.hostContext());
    if (text.length === 0) {
      this.submitting = false;
      return;
    }
    const entries: OpmlEntry[] = parseOpml(text);
    if (entries.length === 0) {
      this.submitting = false;
      this.toast($r('app.string.subs_import_empty'));
      return;
    }
    const added: number = await feedViewModel.importFeeds(entries);
    this.submitting = false;
    this.toast(added > 0
      ? $r('app.string.subs_import_result', added)
      : $r('app.string.subs_import_duplicate'));
  }

  /** 导出 OPML：把当前订阅写进用户选定的文件。 */
  private async exportOpml(): Promise<void> {
    if (feedViewModel.feeds.length === 0) {
      this.toast($r('app.string.subs_export_empty'));
      return;
    }
    this.submitting = true;
    const ok: boolean = await opmlService.exportToFile(this.hostContext(), feedViewModel.exportOpml());
    this.submitting = false;
    if (ok) {
      this.toast($r('app.string.subs_export_success'));
    }
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

  /** 批量移动分组的菜单。 */
  @Builder
  BulkGroupMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.group_ungrouped') })
        .onClick(() => {
          feedViewModel.setFeedGroupMany(this.selectedIds, '');
          this.exitSelect();
        })
      ForEach(feedViewModel.groupNames(), (name: string) => {
        MenuItem({ content: name })
          .onClick(() => {
            feedViewModel.setFeedGroupMany(this.selectedIds, name);
            this.exitSelect();
          })
      }, (name: string) => name)
    }
    .radius($r('app.float.radius_card'))
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
          .fontColor([$r('app.color.hm_brand')])
          .padding($r('app.float.space_s'))
          .opacity(this.selectedIds.length > 0 ? 1 : 0.4)
          .accessibilityText($r('app.string.subs_bulk_move'))
          .enabled(this.selectedIds.length > 0)
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
          .fontColor([$r('app.color.hm_text_secondary')])
          .padding($r('app.float.space_s'))
          .accessibilityText($r('app.string.dialog_cancel'))
          .onClick(() => {
            this.exitSelect();
          })
      }
      .width('100%')
      .height($r('app.float.row_height'))
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
      this.toast(FeedErrorText.of(feedViewModel.errorCode));
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

  /** 分组头：分组名 + 该组订阅源数量。 */
  @Builder
  GroupHeader(row: FeedListItem) {
    Row({ space: $r('app.float.space_s') }) {
      SymbolGlyph(row.groupName.length > 0 ? $r('sys.symbol.folder_fill') : $r('sys.symbol.folder'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([$r('app.color.hm_brand')])
      Text(this.rowLabel(row))
        .fontSize($r('app.float.font_size_section'))
        .fontColor($r('app.color.hm_text_primary'))
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text($r('app.string.home_feed_count', row.count))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
      Blank()
    }
    .width('100%')
    .padding({ left: $r('app.float.space_xs'), right: $r('app.float.space_xs'), top: $r('app.float.space_m') })
  }

  /** 长按拖拽时跟随手指的预览。 */
  @Builder
  DragPreview(row: FeedListItem) {
    Row({ space: $r('app.float.space_s') }) {
      SymbolGlyph(row.isGroup ? $r('sys.symbol.folder') : $r('sys.symbol.folder_fill'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([$r('app.color.hm_brand')])
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

  /** 行内溢出菜单：重命名 / 移动分组 / 删除。 */
  @Builder
  FeedMenu(feed: FeedSource) {
    Menu() {
      MenuItem({ content: $r('app.string.feed_settings_entry') })
        .onClick(() => {
          feedViewModel.openFeedSettings(feed);
          this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_FEED_SETTINGS, ''));
        })
      MenuItem({ content: $r('app.string.subs_rename') })
        .onClick(() => {
          this.editingId = feed.id;
          this.draftTitle = feed.title;
        })
      MenuItem({ content: $r('app.string.subs_edit_url') })
        .onClick(() => {
          this.urlEditId = feed.id;
          this.draftUrl = feed.url;
        })
      MenuItem({ content: $r('app.string.group_clear') })
        .onClick(() => {
          feedViewModel.setFeedGroup(feed.id, '');
        })
      ForEach(feedViewModel.groupNames(), (name: string) => {
        MenuItem({ content: $r('app.string.group_move_to', name) })
          .onClick(() => {
            feedViewModel.setFeedGroup(feed.id, name);
          })
      }, (name: string) => name)
      MenuItem({ content: $r('app.string.group_new') })
        .onClick(() => {
          this.groupEditId = feed.id;
          this.draftGroup = feed.group;
        })
      MenuItem({ content: $r('app.string.feed_move_up') })
        .onClick(() => {
          feedViewModel.moveFeed(feed.id, -1);
        })
      MenuItem({ content: $r('app.string.feed_move_down') })
        .onClick(() => {
          feedViewModel.moveFeed(feed.id, 1);
        })
      MenuItem({ content: $r('app.string.subs_bulk_enter') })
        .onClick(() => {
          this.enterSelect(feed.id);
        })
      MenuItem({ content: $r('app.string.subs_remove') })
        .contentFontColor($r('app.color.hm_danger'))
        .onClick(() => {
          this.confirmRemove(feed);
        })
    }
    .radius($r('app.float.radius_card'))
  }

  /** 未读数徽标；没有未读时退回文章总数（弱化展示）。 */
  @Builder
  CountBadge(feed: FeedSource) {
    if (feed.unreadCount > 0) {
      Text(feed.unreadCount.toString())
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_brand'))
        .padding({
          left: $r('app.float.space_s'),
          right: $r('app.float.space_s'),
          top: $r('app.float.space_xxs'),
          bottom: $r('app.float.space_xxs')
        })
        .backgroundColor($r('app.color.hm_menu_item_selected'))
        .borderRadius($r('app.float.radius_chip'))
        .accessibilityText($r('app.string.home_unread_count', feed.unreadCount))
        .flexShrink(0)
    } else {
      Text($r('app.string.subs_article_count', feed.articleCount))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .maxLines(1)
        .flexShrink(0)
    }
  }

  /** 行副标题用的站点域名；解析不出主机名时退回原地址。 */
  private feedHost(feed: FeedSource): string {
    const host: string = UrlText.host(feed.url);
    return host.length > 0 ? host : feed.url;
  }

  @Builder
  FeedRow(feed: FeedSource) {
    Row({ space: $r('app.float.space_s') }) {
      if (this.selecting) {
        // 只用 onClick 更新选中集合：onChange 会在「选中态被回写到 Checkbox」时再触发一次，
        // 和行点击互相抵消（点整行选不中，几秒后又被自己取消）。
        Checkbox({ name: feed.id })
          .select(this.isSelected(feed.id))
          .onClick(() => {
            this.toggleSelect(feed.id);
          })
      }

      // 信息区点击 = 进入该源的单源视图（返回阅读页只看这个订阅源的文章）。
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
              .backgroundColor($r('app.color.hm_brand'))
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
              .backgroundColor($r('app.color.hm_brand'))
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
              .backgroundColor($r('app.color.hm_brand'))
              .onClick(() => {
                this.saveUrl(feed.id);
              })
          }
          .width('100%')
        } else {
          Row({ space: $r('app.float.space_s') }) {
            Text(feed.title)
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.hm_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            this.CountBadge(feed)
          }
          .width('100%')
        }

        // 一行元信息：站点域名 + 健康状态（原来是 URL / 未读 / 停用 / 上次成功 / 错误最多 6 行）。
        Row({ space: $r('app.float.space_xs') }) {
          Text(this.feedHost(feed))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (!feed.enabled) {
            Text($r('app.string.feed_settings_disabled'))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .flexShrink(0)
          }
          if (feed.failureCount > 0) {
            Text($r('app.string.health_failure_count', feed.failureCount))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_danger'))
              .flexShrink(0)
          } else if (feed.lastUpdated > 0) {
            Text($r('app.string.health_last_success', DateUtil.format(feed.lastUpdated)))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .flexShrink(1)
          }
        }
        .width('100%')

        // 抓取错误：只保留一行，详情去单源设置页看。
        if (feed.lastError.length > 0) {
          Text($r('app.string.subs_error_prefix') + feed.lastError)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_danger'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
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
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .accessibilityText($r('app.string.action_more'))
          .padding($r('app.float.space_xs'))
          .bindMenu(this.FeedMenu(feed), MaterialController.menuOptions({}, appSettings.immersiveOn))
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_m'),
      right: $r('app.float.space_s'),
      top: $r('app.float.space_m'),
      bottom: $r('app.float.space_m')
    })
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  /** 空态：图标 + 说明 + 下一步动作（原来是居中一行灰字）。 */
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
        .backgroundColor($r('app.color.hm_brand'))
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

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ scroller: this.scroller }) {
        // 第 0 项：整块头部（占位 + 添加卡 + 资料库卡 + 订阅源小节标题），随滚动离开。
        ListItem() {
          this.Header()
        }

        if (feedViewModel.feeds.length === 0) {
          ListItem() {
            this.EmptyState()
          }
        } else {
          ForEach(feedViewModel.displayRows(), (row: FeedListItem) => {
            ListItem() {
              if (row.isGroup) {
                this.GroupHeader(row)
              } else {
                this.FeedRow(row.feed)
              }
            }
            .margin({ bottom: $r('app.float.space_s') })
          }, (row: FeedListItem) => row.isGroup ? 'g:' + row.groupName : 'f:' + row.feed.id)

          if (this.selecting) {
            // 多选动作条悬浮在内容下沿：末尾留一段可滚动的余量，最后一行不会被它压住。
            ListItem() {
              Row().width('100%').height($r('app.float.space_3xl'))
            }
          }
        }
      }
      .width('100%')
      .height('100%')
      .padding({
        left: $r('app.float.space_l'),
        right: $r('app.float.space_l'),
        bottom: safeArea.contentBottomInsetVp
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

      if (this.selecting) {
        this.SelectBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
