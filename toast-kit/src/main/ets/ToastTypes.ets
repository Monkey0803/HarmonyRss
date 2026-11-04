/*
 * ToastTypes.ets — toast-kit 的公开配置与单次调用参数。
 *
 * 只暴露与系统 showToast 一一对应的字段，宿主不需要依赖 promptAction 也能完成绝大多数配置。
 */

import { promptAction } from '@kit.ArkUI';

/** 单次 toast 的可选参数；未设置的字段使用全局默认 / 系统默认。 */
export interface ToastOptions {
  /** 展示时长（毫秒）。 */
  duration?: number;
  /** 距底部的距离，例如 '80vp'。 */
  bottom?: string | number;
  /** 显示层级模式。 */
  showMode?: promptAction.ToastShowMode;
  /** 对齐方式。 */
  alignment?: Alignment;
  /** 相对对齐位置的偏移。 */
  offset?: Offset;
}

/** 宿主可对系统 options 做二次加工，例如注入 HDS 沉浸光感材质。 */
export type ToastOptionsDecorator =
  (options: promptAction.ShowToastOptions) => promptAction.ShowToastOptions;

/** 全局默认配置。 */
export interface ToastConfig {
  /** 默认展示时长（毫秒）。 */
  duration?: number;
  /** 默认距底部距离。 */
  bottom?: string | number;
  /** 系统 options 增强器。 */
  enhance?: ToastOptionsDecorator;
}
