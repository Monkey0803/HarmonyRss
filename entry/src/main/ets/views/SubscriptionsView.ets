/*
 * SubscriptionsView.ets — 订阅源管理（订阅源页签内容，纯展示 + 事件上报）。
 *
 * 顶部输入订阅地址并添加（添加前会先抓一次校验可用性）；支持 OPML 导入 / 导出（系统文档选择器）；
 * 下方列出已有订阅源（含未读数）并可删除（删除前确认）。
 * 点击某个订阅源 → 推入该源的单源文章列表页（NavDestination）。
 */

import { common } from '@kit.AbilityKit';
import { FeedListItem, FeedSource } from '../model/Feed';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { FeedError } from '../common/constants/RssConstants';
import { FeedErrorText } from '../common/utils/FeedErrorText';
import { safeArea } from '../service/SafeAreaController';
import { CommonConstants } from '../common/constants/CommonConstants';
import { ToastUtil } from '../common/utils/ToastUtil';
import { opmlService } from '../service/OpmlService';
import { OpmlEntry, parseOpml } from '../service/OpmlCodec';
import { RouterConstants } from '../common/constants/RouterConstants';

@ComponentV2
export struct SubscriptionsView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  @Local inputUrl: string = '';
  @Local submitting: boolean = false;
  /** 就地重命名：正在编辑的订阅源 id 与草稿名。 */
  @Local editingId: string = '';
  @Local draftTitle: string = '';
  /** 就地编辑分组：正在编辑分组的订阅源 id 与草稿分组名。 */
  @Local groupEditId: string = '';
  @Local draftGroup: string = '';

  private hostContext(): common.UIAbilityContext {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    return context as common.UIAbilityContext;
  }

  private toast(message: ResourceStr): void {
    ToastUtil.show(this.getUIContext(), message);
  }

  private async submit(): Promise<void> {
    this.submitting = true;
    const ok: boolean = await feedViewModel.addFeed(this.inputUrl);
    this.submitting = false;
    if (ok) {
      this.inputUrl = '';
    }
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

  private errorText(): ResourceStr {
    return FeedErrorText.of(feedViewModel.errorCode);
  }

  @Builder
  Editor() {
    Column({ space: $r('app.float.space_s') }) {
      Row({ space: $r('app.float.space_s') }) {
        TextInput({ text: this.inputUrl, placeholder: $r('app.string.subs_url_hint') })
          .type(InputType.Normal)
          .fontSize($r('app.float.font_size_body'))
          .layoutWeight(1)
          .onChange((value: string) => {
            this.inputUrl = value;
          })
        Button(this.submitting ? $r('app.string.subs_adding') : $r('app.string.subs_add'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .enabled(!this.submitting)
          .onClick(() => {
            this.submit();
          })
      }
      .width('100%')

      // OPML 迁移：导入 / 导出都走系统文档选择器，无需存储权限。
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

      if (feedViewModel.errorCode !== FeedError.NONE) {
        Text(this.errorText())
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
      }
    }
    .width('100%')
    .padding($r('app.float.space_l'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
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
    this.getUIContext().showAlertDialog(params);
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

  /** 行内溢出菜单：重命名 / 移动分组 / 删除。 */
  @Builder
  FeedMenu(feed: FeedSource) {
    Menu() {
      MenuItem({ content: $r('app.string.subs_rename') })
        .onClick(() => {
          this.editingId = feed.id;
          this.draftTitle = feed.title;
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
      MenuItem({ content: $r('app.string.subs_remove') })
        .contentFontColor($r('app.color.hm_danger'))
        .onClick(() => {
          this.confirmRemove(feed);
        })
    }
    .radius($r('app.float.radius_card'))
  }

  @Builder
  FeedRow(feed: FeedSource) {
    Row({ space: $r('app.float.space_m') }) {
      // 信息区点击 = 进入该源的单源视图（返回阅读页只看这个订阅源的文章）。
      Column({ space: $r('app.float.space_xs') }) {
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
        } else {
          Text(feed.title)
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        Text(feed.url)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (feed.unreadCount > 0) {
          Text($r('app.string.home_unread_count', feed.unreadCount))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_brand'))
        } else {
          Text($r('app.string.subs_article_count', feed.articleCount))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
        if (feed.lastError.length > 0) {
          Text($r('app.string.subs_error_prefix') + feed.lastError)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_danger'))
            .maxLines(2)
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        if (this.editingId !== feed.id && this.groupEditId !== feed.id) {
          feedViewModel.openFeed(feed);
          this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_FEED_ARTICLES, ''));
        }
      })

      if (this.editingId === feed.id || this.groupEditId === feed.id) {
        Button($r('app.string.dialog_cancel'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .onClick(() => {
            this.editingId = '';
            this.groupEditId = '';
          })
      } else {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .padding($r('app.float.space_xs'))
          .bindMenu(this.FeedMenu(feed))
      }
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  build() {
    Column({ space: $r('app.float.space_m') }) {
      // 透明标题栏占位：固定页头（输入区）整体下移，避免被透明标题栏遮挡。
      Row().width('100%').height(safeArea.topInsetVp + CommonConstants.TITLE_BAR_HEIGHT_VP)

      this.Editor()

      if (feedViewModel.feeds.length === 0) {
        Text($r('app.string.subs_empty'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .layoutWeight(1)
          .padding($r('app.float.space_2xl'))
      } else {
        List({ scroller: this.scroller }) {
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
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        // 长按拖拽排序：拖订阅源行 → 单条移动（含跨组）；拖分组头 → 整组换位。
        .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
          return this.DragPreview(feedViewModel.rowAt(itemIndex));
        })
        .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
          if (isSuccess) {
            feedViewModel.reorderByDrag(itemIndex, insertIndex);
          }
        })
        // 悬浮页签栏下的可滚动内容：底部预留 = 页签栏避让高度 + 系统导航条高度。
        .padding({ bottom: safeArea.contentBottomInsetVp })
      }
    }
    .width('100%')
    .height('100%')
    .padding($r('app.float.space_l'))
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
