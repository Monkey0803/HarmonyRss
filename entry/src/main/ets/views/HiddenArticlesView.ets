/*
 * HiddenArticlesView.ets — 已隐藏文章列表（NavDestination 内容）。
 *
 * 数据来自 ruleViewModel.hiddenArticles（轻量列，打开正文按需加载）。每行提供「取消隐藏」：
 * 先写库并刷新已隐藏列表与计数，再让 FeedViewModel 同步内存态并重算主列表（未读数同时恢复）。
 */

import { Article } from '../model/Feed';
import { ruleViewModel } from '../viewmodel/RuleViewModel';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { ArticleListItem } from './ArticleListItem';
import { RouterConstants } from '../common/constants/RouterConstants';
import { safeArea } from '../service/SafeAreaController';
import { ToastUtil } from '../common/utils/ToastUtil';

@ComponentV2
export struct HiddenArticlesView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  @Local opening: boolean = false;

  aboutToAppear(): void {
    ruleViewModel.loadHidden();
  }

  private openArticle(article: Article): void {
    if (this.opening) {
      return;
    }
    this.opening = true;
    feedViewModel.openArticleById(article.id).then((ok: boolean) => {
      this.opening = false;
      if (!ok) {
        ToastUtil.show(this.getUIContext(), $r('app.string.hl_article_gone'));
        return;
      }
      this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_ARTICLE, ''));
    }).catch(() => {
      this.opening = false;
      ToastUtil.show(this.getUIContext(), $r('app.string.hl_article_gone'));
    });
  }

  /** 取消隐藏：已隐藏列表 → 主列表（含未读数）同步恢复。 */
  private async unhide(article: Article): Promise<void> {
    await ruleViewModel.setHidden([article.id], false);
    // FeedViewModel 内存实例里同步 hidden=false 并重算列表 / 未读数（publish）。
    feedViewModel.setHidden([article.id], false);
    await ruleViewModel.refreshHiddenCount();
    ToastUtil.show(this.getUIContext(), $r('app.string.hidden_unhide_done'));
  }

  @Builder
  Header() {
    Column({ space: $r('app.float.space_m') }) {
      Row().width('100%').height(safeArea.contentTopInsetVp)

      Text($r('app.string.hidden_title'))
        .fontSize($r('app.float.font_size_section'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      Text($r('app.string.hidden_hint'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      Text($r('app.string.rule_hidden_entry', ruleViewModel.hiddenCount))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_brand'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  HiddenRow(article: Article) {
    Column({ space: $r('app.float.space_xs') }) {
      ArticleListItem({
        article: article,
        onOpen: () => {
          this.openArticle(article);
        },
        onToggleStar: (id: string) => {
          feedViewModel.toggleStar(id);
        }
      })

      Row() {
        Blank()
        Button($r('app.string.hidden_unhide'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .onClick(() => {
            this.unhide(article);
          })
      }
      .width('100%')
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  build() {
    List({ scroller: this.scroller }) {
      ListItem() {
        this.Header()
      }
      .margin({ bottom: $r('app.float.space_s') })

      if (ruleViewModel.hiddenArticles.length === 0) {
        ListItem() {
          Text($r('app.string.hidden_empty'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding($r('app.float.space_2xl'))
        }
      } else {
        ForEach(ruleViewModel.hiddenArticles, (article: Article) => {
          ListItem() {
            this.HiddenRow(article)
          }
          .margin({ bottom: $r('app.float.space_s') })
        }, (article: Article) => article.id + '_' + article.hidden)
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
