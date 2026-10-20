/*
 * HighlightsView.ets — 标注聚合页（NavDestination 内容）。
 *
 * 把所有文章的标注汇总成一页：按文章分组，组内按时间倒序；支持导出 Markdown / JSON（走系统分享，
 * 可存文件 / 发到其它 App）。点一条标注会打开对应文章并定位到那条标注。
 */

import { HighlightLibraryItem } from '../model/Highlight';
import { articleStore } from '../service/ArticleStore';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { articleActions } from '../service/ArticleActions';
import { toJson, toMarkdown } from '../service/HighlightExport';
import { RouterConstants } from '../common/constants/RouterConstants';
import { safeArea } from '../service/SafeAreaController';
import { ToastUtil } from '../common/utils/ToastUtil';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'HighlightsView';

@ComponentV2
export struct HighlightsView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  @Local items: HighlightLibraryItem[] = [];
  @Local loading: boolean = true;

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.loading = true;
    this.items = await articleStore.listAllHighlights();
    this.loading = false;
  }

  private hostContext(): common.UIAbilityContext {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    return context as common.UIAbilityContext;
  }

  /** 导出并拉起系统分享（分享面板里可存文件 / 发到其它 App）。 */
  private async exportAs(markdown: boolean): Promise<void> {
    const emptyHint: string = this.getUIContext().getHostContext()
      ? '（还没有标注）' : '';
    const text: string = markdown
      ? toMarkdown(this.items, emptyHint)
      : toJson(this.items);
    if (this.items.length === 0) {
      ToastUtil.show(this.getUIContext(), $r('app.string.hl_export_empty'));
      return;
    }
    const ok: boolean = await articleActions.shareText(this.hostContext(),
      markdown ? 'HarmonyRss 标注（Markdown）' : 'HarmonyRss 标注（JSON）', text);
    if (!ok) {
      hilog.warn(DOMAIN, TAG, 'share export failed');
      ToastUtil.show(this.getUIContext(), $r('app.string.toast_action_failed'));
    }
  }

  /** 打开该标注所属文章，并让详情页定位到这条标注。 */
  private openHighlight(entry: HighlightLibraryItem): void {
    const articleId: string = entry.highlight.articleId;
    if (!feedViewModel.hasArticle(articleId)) {
      ToastUtil.show(this.getUIContext(), $r('app.string.hl_article_gone'));
      return;
    }
    feedViewModel.pendingHighlightId = entry.highlight.id;
    feedViewModel.openArticleById(articleId);
    this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_ARTICLE, ''));
  }

  @Builder
  Header() {
    Column({ space: $r('app.float.space_m') }) {
      Row().width('100%').height(safeArea.contentTopInsetVp)

      Row({ space: $r('app.float.space_s') }) {
        Column({ space: $r('app.float.space_xs') }) {
          Text($r('app.string.hl_library_title'))
            .fontSize($r('app.float.font_size_section'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.hm_text_primary'))
          Text($r('app.string.hl_panel_title', this.items.length))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button($r('app.string.hl_export_md'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .onClick(() => {
            this.exportAs(true);
          })
        Button($r('app.string.hl_export_json'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .onClick(() => {
            this.exportAs(false);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private colorOf(color: string): ResourceColor {
    if (color === 'green') {
      return $r('app.color.hl_green');
    }
    if (color === 'blue') {
      return $r('app.color.hl_blue');
    }
    if (color === 'pink') {
      return $r('app.color.hl_pink');
    }
    return $r('app.color.hl_yellow');
  }

  build() {
    List({ scroller: this.scroller }) {
      ListItem() {
        this.Header()
      }

      if (this.loading) {
        ListItem() {
          Text($r('app.string.home_loading'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding($r('app.float.space_2xl'))
        }
      } else if (this.items.length === 0) {
        ListItem() {
          Text($r('app.string.hl_panel_empty'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding($r('app.float.space_2xl'))
        }
      } else {
        ForEach(this.items, (entry: HighlightLibraryItem) => {
          ListItem() {
            Column({ space: $r('app.float.space_xs') }) {
              Row({ space: $r('app.float.space_s') }) {
                Row()
                  .width($r('app.float.feed_dot_size'))
                  .height($r('app.float.feed_dot_size'))
                  .backgroundColor(this.colorOf(entry.highlight.color))
                  .borderRadius($r('app.float.feed_dot_size'))
                Text(entry.articleTitle.length > 0 ? entry.articleTitle : entry.highlight.articleId)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.hm_brand'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')

              Text(entry.highlight.quote)
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.hm_text_primary'))
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')

              if (entry.highlight.note.length > 0) {
                Text(entry.highlight.note)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.hm_text_secondary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }

              if (entry.feedTitle.length > 0) {
                Text(entry.feedTitle)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.hm_text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
            }
            .width('100%')
            .padding($r('app.float.space_m'))
            .backgroundColor($r('app.color.hm_card_background'))
            .borderRadius($r('app.float.radius_card'))
            .alignItems(HorizontalAlign.Start)
          }
          .margin({ bottom: $r('app.float.space_s') })
          .onClick(() => {
            this.openHighlight(entry);
          })
        }, (entry: HighlightLibraryItem) => entry.highlight.id)
      }

      ListItem() {
        Row().width('100%').height(safeArea.bottomInsetVp)
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .clip(false)
    .cachedCount(3, true)
    .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
