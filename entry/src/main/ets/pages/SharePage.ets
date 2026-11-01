/*
 * SharePage.ets — 系统分享详情页（ShareExtensionAbility 加载的页面）。
 *
 * 从 ShareHandoff 取出分享地址，默认预览并保存网页；也可切到订阅源。
 * 扩展进程独立于主界面，这里需自行装配 ViewModel（settings 先就绪，feed 只做轻量加载）。
 */

import { common } from '@kit.AbilityKit';
import { AddFeedPanel } from '../views/AddFeedPanel';
import { SaveWebPagePanel } from '../views/SaveWebPagePanel';
import { settingsViewModel } from '../viewmodel/SettingsViewModel';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { shareHandoff } from '../service/ShareHandoff';

@Entry
@ComponentV2
struct SharePage {
  @Local sharedText: string = '';
  @Local mode: string = 'web';
  @Local ready: boolean = false;
  @Local initFailed: boolean = false;
  @Local saved: boolean = false;

  aboutToAppear(): void {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context !== undefined) {
      settingsViewModel.init(context);
      feedViewModel.ensureReady(context).then(() => { this.ready = true; }).catch(() => {
        this.initFailed = true;
      });
    } else {
      this.initFailed = true;
    }
    this.sharedText = shareHandoff.take().join('\n');
  }

  build() {
    Scroll() {
      Column({ space: $r('app.float.space_m') }) {
        Row({ space: $r('app.float.space_s') }) {
          Button($r('app.string.save_web_title'))
            .buttonStyle(this.mode === 'web' ? ButtonStyleMode.NORMAL : ButtonStyleMode.TEXTUAL)
            .onClick(() => { this.mode = 'web'; })
          Button($r('app.string.home_add_feed_title'))
            .buttonStyle(this.mode === 'feed' ? ButtonStyleMode.NORMAL : ButtonStyleMode.TEXTUAL)
            .onClick(() => { this.mode = 'feed'; })
        }
        if (this.initFailed) {
          Text($r('app.string.save_web_save_failed'))
        } else if (!this.ready) {
          Text($r('app.string.save_web_loading'))
        } else if (this.mode === 'web') {
          SaveWebPagePanel({
            initialText: this.sharedText,
            onSaved: () => { this.saved = true; }
          })
          if (this.saved) {
            Text($r('app.string.save_web_saved'))
          }
        } else {
          AddFeedPanel({
            panelTitle: $r('app.string.share_page_title'),
            initialText: this.sharedText,
            onSubmitResult: () => {}
          })
        }
      }
      .width('100%')
      .padding($r('app.float.space_l'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.start_window_background'))
  }
}
