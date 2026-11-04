/*
 * ToastSetup.ets — 应用级 Toast 配置。
 *
 * 把 Toast 库与 HDS 沉浸光感材质解耦：库本身不认识 HDS / 业务设置，
 * 由应用在初始化时注入 enhance，show 时再读取当前材质开关。
 */

import { promptAction } from '@kit.ArkUI';
import { Toast } from '@rss/toast-kit';
import { appSettings } from '../../model/AppSettings';
import { MaterialController } from '../../service/MaterialController';

/** 注册应用级 Toast 增强（HDS 材质）。幂等，主 Ability 与分享扩展可分别调用。 */
export function setupToast(): void {
  Toast.configure({
    enhance: (options: promptAction.ShowToastOptions): promptAction.ShowToastOptions => {
      return MaterialController.toastOptions(options, appSettings.immersiveOn);
    }
  });
}
