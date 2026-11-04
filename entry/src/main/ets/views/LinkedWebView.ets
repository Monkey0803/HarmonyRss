/* 从文章正文进入的独立网页页；返回导航由外层 HdsNavDestination 负责。 */
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { articleActions } from '../service/ArticleActions';
import { isWebLink } from '../service/LinkNavigation';
import { UrlText } from '../common/utils/UrlText';
import { Toast } from '@monkey0803/toast-kit';
import { safeArea } from '../service/SafeAreaController';
import { themePalette } from '../model/ThemePalette';

@ComponentV2
export struct LinkedWebView {
  @Param initialUrl: string = '';
  @Local currentUrl: string = '';
  @Local failed: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    this.currentUrl = this.initialUrl;
  }

  private async openExternally(): Promise<void> {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const url: string = this.currentUrl.length > 0 ? this.currentUrl : this.initialUrl;
    if (!await articleActions.openInBrowser(context, url)) {
      Toast.show($r('app.string.toast_action_failed'));
    }
  }

  private retry(): void {
    this.failed = false;
    try {
      this.controller.loadUrl(this.currentUrl.length > 0 ? this.currentUrl : this.initialUrl);
    } catch (err) {
      this.failed = true;
    }
  }

  private handleNewWindow(event: OnWindowNewEvent): void {
    event.handler.setWebController(null);
    if (event.isUserTrigger && isWebLink(event.targetUrl)) {
      try {
        this.controller.loadUrl(event.targetUrl);
      } catch (err) {
        this.failed = true;
      }
    } else if (event.isUserTrigger && event.targetUrl.startsWith('mailto:')) {
      this.openSystemLink(event.targetUrl);
    } else if (event.isUserTrigger && event.targetUrl.startsWith('tel:')) {
      this.openSystemLink(event.targetUrl);
    }
  }

  private openSystemLink(link: string): void {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    articleActions.openInBrowser(context, link).then((ok: boolean): void => {
      if (!ok) {
        Toast.show($r('app.string.toast_action_failed'));
      }
    });
  }

  build() {
    Column() {
      Row().width('100%').height(safeArea.contentTopInsetVp)
      Row({ space: $r('app.float.space_s') }) {
        Text(UrlText.host(this.currentUrl.length > 0 ? this.currentUrl : this.initialUrl))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Button($r('app.string.action_open_browser'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontColor(themePalette.accent())
          .onClick(() => { this.openExternally(); })
      }
      .width('100%')
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })

      Stack() {
        Web({ src: this.initialUrl, controller: this.controller })
          .width('100%')
          .height('100%')
          .darkMode(WebDarkMode.Auto)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .multiWindowAccess(true)
          .onWindowNew((event: OnWindowNewEvent): void => this.handleNewWindow(event))
          .onLoadIntercept((event: OnLoadInterceptEvent): boolean => {
            const request: WebResourceRequest = event.data;
            if (!request.isMainFrame() || !request.isRequestGesture()) {
              return false;
            }
            const link: string = request.getRequestUrl();
            if (link.startsWith('mailto:') || link.startsWith('tel:')) {
              this.openSystemLink(link);
              return true;
            }
            return false;
          })
          .onPageBegin((event: OnPageBeginEvent): void => {
            if (isWebLink(event.url)) {
              this.currentUrl = event.url;
            }
            this.failed = false;
          })
          .onPageEnd((event: OnPageEndEvent): void => {
            if (isWebLink(event.url)) {
              this.currentUrl = event.url;
            }
          })
          .onErrorReceive((event: OnErrorReceiveEvent): void => {
            if (event.request.isMainFrame()) {
              this.failed = true;
            }
          })
          .onHttpErrorReceive((event: OnHttpErrorReceiveEvent): void => {
            if (event.request.isMainFrame()) {
              this.failed = true;
            }
          })
        if (this.failed) {
          Column({ space: $r('app.float.space_m') }) {
            Text($r('app.string.article_web_load_failed'))
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.hm_text_primary'))
            Row({ space: $r('app.float.space_s') }) {
              Button($r('app.string.action_retry'))
                .fontColor($r('app.color.hm_on_brand'))
                .backgroundColor(themePalette.fill())
                .onClick(() => { this.retry(); })
              Button($r('app.string.action_open_browser'))
                .buttonStyle(ButtonStyleMode.TEXTUAL)
                .fontColor(themePalette.accent())
                .onClick(() => { this.openExternally(); })
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor($r('app.color.hm_web_surface'))
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.hm_web_surface'))
  }
}
