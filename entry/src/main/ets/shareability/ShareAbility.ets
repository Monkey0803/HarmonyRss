/*
 * ShareAbility.ets — 系统分享接收入口（ShareExtensionAbility）。
 *
 * 用户在其它 App 里对链接 / 文本发起「分享」，在系统分享面板里选择本应用后，系统会拉起这个扩展能力。
 * 分享内容通过 `systemShare.getSharedData(want)` 解析（官方路径），再加载分享详情页（SharePage）让用户
 * 预览 / 确认订阅。
 *
 * 说明：扩展能力运行在独立上下文，不能依赖主界面已初始化的内存态；SharePage 会自行完成
 * settingsViewModel / feedViewModel 的装配。解析失败时按官方要求 terminateSelf，避免占用分享通道。
 */

import { ShareExtensionAbility, UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { shareIntent } from '../service/ShareIntent';
import { shareHandoff } from '../service/ShareHandoff';

const DOMAIN: number = 0x0000;
const TAG: string = 'ShareAbility';

export default class ShareAbility extends ShareExtensionAbility {
  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    systemShare.getSharedData(want)
      .then((data: systemShare.SharedData) => {
        let urls: string[] = shareIntent.extractFromSharedData(data);
        if (urls.length === 0) {
          // 解析出的记录里没有 http(s) 地址时，退回对 want 参数的尽力提取。
          urls = shareIntent.extractSharedUrls(want);
        }
        shareHandoff.set(urls);
        hilog.info(DOMAIN, TAG, 'share session created, extracted=%{public}d', urls.length);
        session.loadContent('pages/SharePage');
      })
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'getSharedData failed: %{public}d', error.code);
        session.terminateSelf();
      });
  }
}
