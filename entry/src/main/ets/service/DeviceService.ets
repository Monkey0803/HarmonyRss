/*
 * DeviceService.ets — 窗口宽度断点（Model 层：屏蔽 mediaquery 细节）。
 *
 * 用 UIContext.getMediaQuery() 的 matchMediaSync（全局 @ohos.mediaquery 自 API 18 起废弃）。
 * 只负责「结构要不要变」的两个布尔量：
 *   split：≥600vp，HdsNavigation 走「列表 | 详情」两栏；
 *   rail ：≥1000vp，底部页签换成 HdsSideBar + HdsSideMenu 侧边栏（三栏）。
 *
 * 唯一 owner 是外壳 pages/Index：只有它调 start / stop，子页面只读 deviceService.rail / split，
 * 否则子页面的 stop() 会把外壳的订阅一起干掉。
 */

import { mediaquery } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { BreakpointConstants } from '../common/constants/BreakpointConstants';

@ObservedV2
export class DeviceService {
  /** 是否走「列表 | 详情」两栏。 */
  @Trace split: boolean = false;
  /** 是否走侧边栏外壳（三栏）。 */
  @Trace rail: boolean = false;

  private splitListener: mediaquery.MediaQueryListener | undefined = undefined;
  private railListener: mediaquery.MediaQueryListener | undefined = undefined;

  /** 订阅断点变化（幂等：重复调用不会重复注册）。 */
  start(uiContext: UIContext): void {
    if (this.splitListener !== undefined || this.railListener !== undefined) {
      return;
    }
    try {
      const query = uiContext.getMediaQuery();
      const splitListener: mediaquery.MediaQueryListener = query.matchMediaSync(BreakpointConstants.SPLIT_MEDIA_QUERY);
      this.split = splitListener.matches;
      splitListener.on('change', (result: mediaquery.MediaQueryResult) => {
        this.split = result.matches;
      });
      this.splitListener = splitListener;

      const railListener: mediaquery.MediaQueryListener = query.matchMediaSync(BreakpointConstants.RAIL_MEDIA_QUERY);
      this.rail = railListener.matches;
      railListener.on('change', (result: mediaquery.MediaQueryResult) => {
        this.rail = result.matches;
      });
      this.railListener = railListener;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('DeviceService.start failed: ' + error.code.toString());
    }
  }

  /** 退订（窗口销毁时调用）。 */
  stop(): void {
    const splitListener: mediaquery.MediaQueryListener | undefined = this.splitListener;
    if (splitListener !== undefined) {
      try {
        splitListener.off('change');
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        console.error('DeviceService.off(split) failed: ' + error.code.toString());
      }
      this.splitListener = undefined;
    }
    const railListener: mediaquery.MediaQueryListener | undefined = this.railListener;
    if (railListener !== undefined) {
      try {
        railListener.off('change');
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        console.error('DeviceService.off(rail) failed: ' + error.code.toString());
      }
      this.railListener = undefined;
    }
  }
}

/** 全局唯一实例。 */
export const deviceService: DeviceService = new DeviceService();
