/*
 * NetworkStatus.ets — 当前默认网络是否可用 / 是否非计费网络。
 *
 * 只是只读查询，不订阅网络变化；需要 ohos.permission.GET_NETWORK_INFO。
 * 任何异常都按离线 / 计费处理：查询失败时宁可不自动同步，也不该偷偷走流量。
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

  /**
   * 默认网络是否为「非计费」承载（Wi-Fi / 以太网）。
   * 查询失败按 false 处理：调用方据此跳过自动同步，避免误走蜂窝流量。
   */
  static isUnmetered(): boolean {
    try {
      if (!connection.hasDefaultNetSync()) {
        return false;
      }
      const net: connection.NetHandle = connection.getDefaultNetSync();
      if (net.netId === 0) {
        return false;
      }
      const capabilities: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);
      const bearers: connection.NetBearType[] = capabilities.bearerTypes;
      for (let i = 0; i < bearers.length; i += 1) {
        const bearer: connection.NetBearType = bearers[i];
        if (bearer === connection.NetBearType.BEARER_WIFI ||
          bearer === connection.NetBearType.BEARER_ETHERNET) {
          return true;
        }
      }
      return false;
    } catch (err) {
      const error: Error = err as Error;
      hilog.warn(DOMAIN, TAG, 'net capabilities failed: %{public}s',
        error.message !== undefined ? error.message : 'unknown');
      return false;
    }
  }
}
