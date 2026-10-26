/*
 * NetworkStatus.ets — 当前默认网络是否可用（隐私页展示用）。
 *
 * 只是只读查询，不订阅网络变化；需要 ohos.permission.GET_NETWORK_INFO。
 * 任何异常都按离线处理：隐私页展示状态失败不应影响页面本身。
 */

import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'NetworkStatus';

export class NetworkStatus {
  /** 默认网络是否已激活。 */
  static isOnline(): boolean {
    try {
      return connection.hasDefaultNetSync();
    } catch (err) {
      const error: Error = err as Error;
      hilog.warn(DOMAIN, TAG, 'network status failed: %{public}s',
        error.message !== undefined ? error.message : 'unknown');
      return false;
    }
  }
}
