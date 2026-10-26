/*
 * PrivacyViewModel.ets — 隐私与数据页的状态（@ObservedV2）。
 *
 * 只读聚合：本机能力开关、系统授权、网络状态、远端账号与翻译缓存条数。
 * 清空翻译缓存是唯一写操作（只动独立翻译缓存库）。
 */

import { common } from '@kit.AbilityKit';
import { appSettings } from '../model/AppSettings';
import { RemoteAccount } from '../model/Remote';
import { notifyService } from '../service/NotifyService';
import { NetworkStatus } from '../service/NetworkStatus';
import { translationService } from '../service/TranslationService';
import { remoteAccountStore } from '../service/RemoteAccountStore';

@ObservedV2
export class PrivacyViewModel {
  /** 系统通知授权。 */
  @Trace notificationOn: boolean = false;
  /** 当前默认网络。 */
  @Trace networkOnline: boolean = false;
  /** 联网翻译开关。 */
  @Trace translationOn: boolean = false;
  /** 翻译缓存条数。 */
  @Trace translationCacheCount: number = 0;
  /** 远端账号是否已连接。 */
  @Trace remoteConnected: boolean = false;
  /** 远端账号地址（未配置为空串）。 */
  @Trace remoteHost: string = '';
  /** 首次装配完成。 */
  @Trace ready: boolean = false;
  /** 清缓存进行中。 */
  @Trace clearing: boolean = false;

  /** 读取全部状态（进入页面时调用）。 */
  async refresh(context: common.Context): Promise<void> {
    this.notificationOn = notifyService.isEnabled();
    this.networkOnline = NetworkStatus.isOnline();
    this.translationOn = appSettings.translateEnabled;
    this.translationCacheCount = await translationService.cacheCount(context);
    try {
      const account: RemoteAccount | undefined = await remoteAccountStore.loadAccount();
      this.remoteConnected = account !== undefined;
      this.remoteHost = account !== undefined ? account.baseUrl : '';
    } catch (err) {
      this.remoteConnected = false;
      this.remoteHost = '';
    }
    this.ready = true;
  }

  /** 清空翻译缓存，返回清理条数并刷新计数。 */
  async clearTranslationCache(context: common.Context): Promise<number> {
    this.clearing = true;
    try {
      const cleared: number = await translationService.clearCache(context);
      this.translationCacheCount = 0;
      return cleared;
    } finally {
      this.clearing = false;
    }
  }
}

/** 全局唯一 ViewModel。 */
export const privacyViewModel: PrivacyViewModel = new PrivacyViewModel();
