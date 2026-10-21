/*
 * SharePage.ets — 系统分享详情页（ShareExtensionAbility 加载的页面）。
 *
 * 从 ShareHandoff 取出分享解析出的地址，复用 AddFeedPanel 完成「预览 → 确认订阅」。
 * 扩展进程独立于主界面，这里需自行装配 ViewModel（settings 先就绪，feed 只做轻量加载）。
 */

import { common } from '@kit.AbilityKit';
import { AddFeedPanel } from '../views/AddFeedPanel';
import { settingsViewModel } from '../viewmodel/SettingsViewModel';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { shareHandoff } from '../service/ShareHandoff';

@Entry
@ComponentV2
struct SharePage {
  @Local sharedText: string = '';

  aboutToAppear(): void {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context !== undefined) {
      settingsViewModel.init(context);
      feedViewModel.ensureReady(context);
    }
    this.sharedText = shareHandoff.take().join('\n');
  }

  build() {
    Scroll() {
      Column({ space: $r('app.float.space_m') }) {
        AddFeedPanel({
          panelTitle: $r('app.string.share_page_title'),
          prefillFromClipboard: false,
          initialText: this.sharedText,
          onSubmitResult: () => {
          }
        })
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
