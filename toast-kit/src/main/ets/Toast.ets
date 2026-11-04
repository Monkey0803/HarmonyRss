/*
 * Toast.ets — 可复用的系统 Toast 封装。
 *
 * 设计目标：
 *   - 调用方不再需要 `this.getUIContext()`，初始化一次后直接 `Toast.show(message)`。
 *   - 底层仍是 `UIContext.getPromptAction().showToast`，层级 / 安全区 / 无障碍交给系统。
 *   - 无上下文时只告警一次并静默返回，提示失败不允许影响业务流程。
 *   - 宿主可通过 `configure({ enhance })` 注入材质等 options 加工逻辑，本库不依赖任何业务代码。
 */

import { promptAction, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ToastConfig, ToastOptions, ToastOptionsDecorator } from './ToastTypes';

const DOMAIN: number = 0x0000;
const TAG: string = 'ToastKit';

/** 已挂载上下文 + 引用计数（同一页面重复 attach / 多页面共享同一 UIContext 均安全）。 */
class AttachedContext {
  uiContext: UIContext;
  count: number;

  constructor(uiContext: UIContext, count: number) {
    this.uiContext = uiContext;
    this.count = count;
  }
}

/**
 * 全局 Toast 入口。
 *
 * 典型接入：
 *   EntryAbility.onWindowStageCreate: Toast.init(windowStage)
 *   UIExtension 页面 aboutToAppear:  Toast.attach(this.getUIContext())
 *   任意位置:                        Toast.show(message)
 */
export class Toast {
  private static windowStage: window.WindowStage | undefined = undefined;
  private static mainContext: UIContext | undefined = undefined;
  private static attached: AttachedContext[] = [];
  private static config: ToastConfig = {};
  private static warned: boolean = false;

  /**
   * 主 UIAbility 在 `onWindowStageCreate` 调用一次。
   * 重复调用（接续恢复 / 窗口重建）会替换 stage 并清空旧窗口缓存。
   */
  static init(windowStage: window.WindowStage): void {
    Toast.windowStage = windowStage;
    Toast.mainContext = undefined;
    Toast.warned = false;
  }

  /**
   * 手动挂载一个 UIContext（UIExtensionAbility 页面等没有 windowStage 的场景）。
   * 后挂载者优先；同一个 UIContext 重复挂载只累计引用计数。
   */
  static attach(uiContext: UIContext): void {
    for (let i = 0; i < Toast.attached.length; i += 1) {
      if (Toast.attached[i].uiContext === uiContext) {
        Toast.attached[i].count += 1;
        return;
      }
    }
    Toast.attached.push(new AttachedContext(uiContext, 1));
    Toast.warned = false;
  }

  /** 移除之前挂载的 UIContext；引用计数归零才真正移除。 */
  static detach(uiContext: UIContext): void {
    for (let i = Toast.attached.length - 1; i >= 0; i -= 1) {
      if (Toast.attached[i].uiContext === uiContext) {
        Toast.attached[i].count -= 1;
        if (Toast.attached[i].count <= 0) {
          Toast.attached.splice(i, 1);
        }
        return;
      }
    }
  }

  /** Ability 销毁时清理全部缓存。 */
  static release(): void {
    Toast.windowStage = undefined;
    Toast.mainContext = undefined;
    Toast.attached = [];
    Toast.warned = false;
  }

  /** 合并全局默认配置；未传的字段保持原值。 */
  static configure(config: ToastConfig): void {
    if (config.duration !== undefined) {
      Toast.config.duration = config.duration;
    }
    if (config.bottom !== undefined) {
      Toast.config.bottom = config.bottom;
    }
    if (config.enhance !== undefined) {
      Toast.config.enhance = config.enhance;
    }
  }

  /** 使用当前激活的 UIContext 弹一条提示。 */
  static show(message: ResourceStr, options?: ToastOptions): void {
    const context: UIContext | undefined = Toast.resolveContext();
    if (context === undefined) {
      if (!Toast.warned) {
        Toast.warned = true;
        hilog.warn(DOMAIN, TAG, 'no UIContext; call Toast.init(windowStage) or Toast.attach(uiContext) first');
      }
      return;
    }
    Toast.showIn(context, message, options);
  }

  /** 在指定 UIContext 上弹一条提示（多窗口 / 特殊场景显式指定）。 */
  static showIn(uiContext: UIContext, message: ResourceStr, options?: ToastOptions): void {
    try {
      const params: promptAction.ShowToastOptions = Toast.buildOptions(message, options);
      const enhance: ToastOptionsDecorator | undefined = Toast.config.enhance;
      const finalOptions: promptAction.ShowToastOptions =
        enhance === undefined ? params : enhance(params);
      uiContext.getPromptAction().showToast(finalOptions);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'showToast failed: %{public}d', error.code);
    }
  }

  /** 已挂载上下文优先，其次主窗口，最后尝试从 windowStage 惰性解析。 */
  private static resolveContext(): UIContext | undefined {
    if (Toast.attached.length > 0) {
      return Toast.attached[Toast.attached.length - 1].uiContext;
    }
    if (Toast.mainContext !== undefined) {
      return Toast.mainContext;
    }
    const stage: window.WindowStage | undefined = Toast.windowStage;
    if (stage === undefined) {
      return undefined;
    }
    try {
      Toast.mainContext = stage.getMainWindowSync().getUIContext();
      return Toast.mainContext;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getMainWindowSync failed: %{public}d', error.code);
      return undefined;
    }
  }

  /** 组装系统 options：单次参数 > 全局配置 > 系统默认。 */
  private static buildOptions(message: ResourceStr, options?: ToastOptions): promptAction.ShowToastOptions {
    const params: promptAction.ShowToastOptions = { message: message };

    let duration: number | undefined = Toast.config.duration;
    if (options !== undefined && options.duration !== undefined) {
      duration = options.duration;
    }
    if (duration !== undefined) {
      params.duration = duration;
    }

    let bottom: string | number | undefined = Toast.config.bottom;
    if (options !== undefined && options.bottom !== undefined) {
      bottom = options.bottom;
    }
    if (bottom !== undefined) {
      params.bottom = bottom;
    }

    if (options !== undefined && options.showMode !== undefined) {
      params.showMode = options.showMode;
    }
    if (options !== undefined && options.alignment !== undefined) {
      params.alignment = options.alignment;
    }
    if (options !== undefined && options.offset !== undefined) {
      params.offset = options.offset;
    }
    return params;
  }
}
