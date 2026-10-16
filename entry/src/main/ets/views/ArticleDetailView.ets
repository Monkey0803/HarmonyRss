/*
 * ArticleDetailView.ets — 文章详情（NavDestination 内容，纯展示）。
 *
 * 全文阅读：默认用 ArkWeb 的 Web 组件直接加载文章原文链接，这样 RSS 只给摘要时也能读到全文；
 * 链接为空、或用户想省流时，可切到「提取正文」——用解析层从 feed 内容里抽出的纯文本。
 * 只从 FeedViewModel 读取当前文章，不在视图里做业务逻辑。
 */

import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  HdsActionBar,
  ActionBarButton,
  ActionBarStyle,
  HdsSnackBar,
  SnackBarIconOptions,
  SnackBarMessageOptions,
  SnackBarOperationOptions,
  SnackBarStyleOptions,
  SnackBarOperationType
} from '@kit.UIDesignKit';
import { Article } from '../model/Feed';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { DateUtil } from '../common/utils/DateUtil';
import { safeArea } from '../service/SafeAreaController';
import { CommonConstants } from '../common/constants/CommonConstants';
import { articleActions } from '../service/ArticleActions';
import { settingsViewModel } from '../viewmodel/SettingsViewModel';
import { ChoiceOption, READER_FONT_OPTIONS } from '../model/SettingsOptions';
import { ToastUtil } from '../common/utils/ToastUtil';
import { readerStyle } from '../service/ReaderStyle';
import { appSettings } from '../model/AppSettings';
import { ReaderTypography } from '../common/constants/SettingsConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'ArticleDetailView';

@ComponentV2
export struct ArticleDetailView {
  /** true：网页原文；false：提取正文。 */
  @Local showWeb: boolean = true;
  @Local loading: boolean = true;
  /** HdsActionBar 展开态：展开时同时显示两侧按钮。 */
  @Local isExpand: boolean = true;
  private webController: webview.WebviewController = new webview.WebviewController();
  /** 提取正文模式的滚动控制器：用于恢复 / 记录阅读进度。 */
  /** 提取正文模式的可滚动控制器（由外层 HdsNavDestination 绑定，用于标题栏材质随滚动跟手渐变 + 阅读进度）。 */
  @Param scroller: Scroller = new Scroller();
  /** 网页原文只在首次加载完成时恢复一次进度，避免页面内跳转后又被拉回去。 */
  private webProgressRestored: boolean = false;

  private hostContext(): common.UIAbilityContext {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    return context as common.UIAbilityContext;
  }

  private toast(message: ResourceStr): void {
    ToastUtil.show(this.getUIContext(), message);
  }

  /**
   * 即时操作弹窗（HdsSnackBar）：比 Toast 更适合「已完成 + 可关闭」的反馈。
   * 每次按需创建实例，避免在组件字段里提前拿 UIContext。
   */
  private snack(title: ResourceStr): void {
    const bar: HdsSnackBar = new HdsSnackBar(this.getUIContext());
    const icon: SnackBarIconOptions = { icon: $r('sys.symbol.checkmark_circle') };
    const message: SnackBarMessageOptions = { title: title };
    const operation: SnackBarOperationOptions = {
      operationType: SnackBarOperationType.CLOSE_BUTTON_ONLY,
      closeButtonAccessibilityText: $r('app.string.snack_dismiss')
    };
    const style: SnackBarStyleOptions = { duration: 3000 };
    bar.show(icon, message, operation, style);
  }

  private async copyLink(article: Article): Promise<void> {
    const ok: boolean = await articleActions.copyText(article.link.length > 0 ? article.link : article.title);
    if (ok) {
      this.snack($r('app.string.snack_link_copied'));
    } else {
      this.toast($r('app.string.toast_action_failed'));
    }
  }

  private async openInBrowser(article: Article): Promise<void> {
    const ok: boolean = await articleActions.openInBrowser(this.hostContext(), article.link);
    if (!ok) {
      this.toast($r('app.string.toast_action_failed'));
    }
  }

  private async shareArticle(article: Article): Promise<void> {
    const ok: boolean = await articleActions.share(this.hostContext(), article.title, article.link);
    if (!ok) {
      this.toast($r('app.string.toast_action_failed'));
    }
  }

  /** 溢出菜单：复制链接 / 浏览器打开 / 分享。 */
  @Builder
  ActionsMenu(article: Article) {
    Menu() {
      MenuItem({ content: $r('app.string.action_copy_link') })
        .onClick(() => {
          this.copyLink(article);
        })
      MenuItem({ content: $r('app.string.action_open_browser') })
        .onClick(() => {
          this.openInBrowser(article);
        })
      MenuItem({ content: $r('app.string.action_share') })
        .onClick(() => {
          this.shareArticle(article);
        })
    }
    .radius($r('app.float.radius_card'))
  }

  /**
   * 阅读排版快捷菜单：不必跳设置页就能换正文字号。
   * 网页原文的排版只能靠注入，所以改完要立刻用 readerStyle 重新注入一次（幂等）。
   */
  @Builder
  FontMenu() {
    Menu() {
      ForEach(READER_FONT_OPTIONS.options, (option: ChoiceOption) => {
        MenuItem({ content: option.label })
          .contentFontColor(appSettings.readerFont === option.id
            ? $r('app.color.hm_brand')
            : $r('app.color.hm_text_primary'))
          .onClick(() => {
            this.applyFontSize(option.id);
          })
      }, (option: ChoiceOption) => option.id)
    }
    .radius($r('app.float.radius_card'))
  }

  private applyFontSize(id: string): void {
    settingsViewModel.setReaderFont(id);
    if (this.showWeb) {
      readerStyle.apply(this.webController);
    }
  }

  /** 离开详情页：网页原文的滚动位置只能问页面要，所以在这里取一次写回。 */
  aboutToDisappear(): void {
    this.persistWebProgress();
  }

  /** 提取正文：进入页面时恢复到上次读到的位置（ArkUI Scroll 的 offset，vp）。 */
  private restoreTextProgress(): void {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || article.progress <= 0) {
      return;
    }
    this.scroller.scrollTo({ xOffset: 0, yOffset: article.progress });
  }

  /**
   * 网页原文：首次加载完成后恢复进度；保存的也是 CSS px（window.scrollY），坐标系一致。
   *
   * 注意不能只 scrollTo 一次：SPA（如 YouTube）在 onPageEnd 之后还会继续长内容，
   * 那时文档还太短，一次性滚动会被忽略 / 被后续渲染顶掉。所以注入一段带重试的脚本，
   * 每 250ms 校正一次，最多 3 秒，或者一旦真的落到目标位置就停。
   */
  private restoreWebProgress(): void {
    if (this.webProgressRestored) {
      return;
    }
    this.webProgressRestored = true;
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || article.progress <= 0) {
      return;
    }
    const target: string = Math.round(article.progress).toString();
    const script: string = '(function(){var y=' + target + ';var n=0;' +
      'var iv=setInterval(function(){window.scrollTo(0,y);n++;' +
      'if(n>12||window.scrollY>=y-4){clearInterval(iv);}},250);})()';
    this.webController
      .runJavaScript(script)
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'restore web progress failed: %{public}d', err.code);
      });
  }

  /**
   * 网页原文的进度只能在页面里读：window.scrollY。
   * 回调是异步的，组件此时可能已在销毁中；即使失败也只是「这次没记住」，不影响阅读。
   */
  private persistWebProgress(): void {
    const article: Article | undefined = feedViewModel.currentArticle();
    if (article === undefined || !this.showWeb || article.link.length === 0) {
      return;
    }
    this.webController.runJavaScript('window.scrollY', (err: BusinessError, value: string) => {
      if (err) {
        hilog.warn(DOMAIN, TAG, 'read web progress failed: %{public}d', err.code);
        return;
      }
      const y: number = Number(value);
      if (Number.isFinite(y) && y >= 0) {
        feedViewModel.saveProgress(article.id, y);
      }
    });
  }

  /** 文章标题 + 来源 + 时间 + 阅读模式切换。 */
  @Builder
  Meta(article: Article) {
    Column({ space: $r('app.float.space_xs') }) {
      Text(article.title)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .fontWeight(FontWeight.Medium)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row({ space: $r('app.float.space_s') }) {
        Text(article.feedTitle)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (article.author.length > 0) {
          Text(article.author)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text(DateUtil.format(article.publishedAt))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        if (article.link.length > 0) {
          Button(this.showWeb ? $r('app.string.article_mode_text') : $r('app.string.article_mode_web'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_brand'))
            .onClick(() => {
              this.showWeb = !this.showWeb;
              this.loading = true;
            })
        }

        // 阅读排版快捷入口：就地换正文字号。
        SymbolGlyph($r('sys.symbol.textformat'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .padding($r('app.float.space_xs'))
          .bindMenu(this.FontMenu())

        SymbolGlyph(article.starred ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([article.starred ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])
          .padding($r('app.float.space_xs'))
          .onClick(() => {
            feedViewModel.toggleStar(article.id);
          })

        SymbolGlyph($r('sys.symbol.more'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .padding($r('app.float.space_xs'))
          .bindMenu(this.ActionsMenu(article))
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_l'))
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 底部操作栏（HdsActionBar）：主按钮 = 收藏（星标切换），左 = 阅读模式切换，右 = 分享 / 浏览器打开。
   * isPrimaryIconChanged 驱动主按钮在 baseIcon / altIcon 之间切换，表达「已收藏」状态。
   */
  @Builder
  ActionBar(article: Article) {
    HdsActionBar({
      startButtons: [
        new ActionBarButton({
          baseIcon: this.showWeb ? $r('sys.symbol.doc_text') : $r('sys.symbol.link'),
          onClick: () => {
            this.showWeb = !this.showWeb;
            this.loading = true;
          }
        })
      ],
      endButtons: [
        new ActionBarButton({
          baseIcon: $r('sys.symbol.share'),
          onClick: () => {
            this.shareArticle(article);
          }
        })
      ],
      primaryButton: new ActionBarButton({
        baseIcon: $r('sys.symbol.star'),
        altIcon: $r('sys.symbol.star_fill'),
        hoverTips: article.starred ? $r('app.string.action_unstar') : $r('app.string.action_star'),
        onClick: () => {
          feedViewModel.toggleStar(article.id);
        }
      }),
      actionBarStyle: new ActionBarStyle({
        isPrimaryIconChanged: article.starred
      }),
      isExpand: this.isExpand
    })
    .margin({ top: $r('app.float.space_l'), bottom: $r('app.float.space_l') })
  }

  /** 网页原文：全文阅读。 */
  @Builder
  WebBody(article: Article) {
    Stack() {
      Web({ src: article.link, controller: this.webController })
        .width('100%')
        .height('100%')
        .darkMode(WebDarkMode.Auto)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .onPageEnd(() => {
          this.loading = false;
          // 网页原文的排版只能靠注入：按设置覆盖正文字号 / 行距。
          readerStyle.apply(this.webController);
          // 排版注入完成后再恢复进度，避免字号变化导致落点偏移。
          this.restoreWebProgress();
        })

      if (this.loading) {
        // 加载完成前用一层**不透明**的主题面板盖住 Web 的默认白底，转圈放在面板上。
        // 否则深色主题下转场时会滑进来一整块白色，页面加载完才翻成深色（白闪）。
        Column() {
          LoadingProgress()
            .width($r('app.float.web_loading_size'))
            .height($r('app.float.web_loading_size'))
            .color($r('app.color.hm_brand'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.hm_web_surface'))
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 提取正文：feed 里能拿到的纯文本 + 原文链接。 */
  @Builder
  TextBody(article: Article) {
    Scroll(this.scroller) {
      Column({ space: $r('app.float.space_m') }) {
        Text(article.content.length > 0 ? article.content : $r('app.string.article_no_content'))
          .fontSize(ReaderTypography.fontSize(appSettings.readerFont))
          .lineHeight(ReaderTypography.fontSize(appSettings.readerFont)
            * ReaderTypography.lineHeight(appSettings.readerLine))
          .fontColor($r('app.color.hm_text_primary'))
          .width('100%')

        if (article.link.length > 0) {
          Column({ space: $r('app.float.space_xs') }) {
            Text($r('app.string.article_open_link'))
              .fontSize($r('app.float.font_size_section'))
              .fontColor($r('app.color.hm_text_secondary'))
            Text(article.link)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_brand'))
              .width('100%')
          }
          .width('100%')
          .padding($r('app.float.space_m'))
          .backgroundColor($r('app.color.hm_card_background'))
          .borderRadius($r('app.float.radius_card'))
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l'), bottom: $r('app.float.space_3xl') })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .clip(false)
    .align(Alignment.TopStart)
    .onAppear(() => {
      // 布局就绪后恢复到上次读到的位置。
      this.restoreTextProgress();
    })
    .onScrollStop(() => {
      const current: Article | undefined = feedViewModel.currentArticle();
      if (current !== undefined) {
        feedViewModel.saveProgress(current.id, this.scroller.currentOffset().yOffset);
      }
    })
  }

  @Builder
  Content(article: Article | undefined) {
    if (article !== undefined) {
      this.Meta(article)
      if (article.link.length > 0 && this.showWeb) {
        this.WebBody(article)
      } else {
        this.TextBody(article)
      }
      this.ActionBar(article)
    }
  }

  build() {
    Column() {
      // 透明标题栏占位：首屏内容顶部预留「状态栏 + 标题栏」高度。
      Row().width('100%').height(safeArea.topInsetVp + CommonConstants.TITLE_BAR_HEIGHT_VP)

      this.Content(feedViewModel.currentArticle())
    }
    .width('100%')
    .height('100%')
    // 详情页没有页签栏：底部只按系统导航条内缩。
    .padding({ bottom: safeArea.bottomInsetVp })
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
