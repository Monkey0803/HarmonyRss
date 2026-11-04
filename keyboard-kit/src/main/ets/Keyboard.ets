/*
 * Keyboard.ets — 可复用的软键盘（输入法）管理库。
 *
 * 设计目标：
 *   - 调用方初始化一次后可直接 Keyboard.dismiss() / Keyboard.requestFocus(id)，无需再取 UIContext。
 *   - 把「收起键盘」「请求焦点」「键盘避让模式切换」收敛到同一入口，避免各页面各写一套。
 *   - 避让模式按 UIContext 维护栈，支持嵌套进入 / 退出，恢复顺序与压入顺序严格对应。
 *   - 无上下文或系统 API 异常时只记日志并静默返回，键盘处理失败不允许影响业务流程。
 *   - 不包含任何 UI 组件与状态管理装饰器，可与 V1 / V2 工程共存。
 */

import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'KeyboardKit';

/** 已挂载上下文 + 引用计数（同一页面重复 attach / 多页面共享同一 UIContext 均安全）。 */
class AttachedContext {
  uiContext: UIContext;
  count: number;

  constructor(uiContext: UIContext, count: number) {
    this.uiContext = uiContext;
    this.count = count;
  }
}

/** 单个 UIContext 的避让模式栈：栈内存放的是每次 push 之前的模式。 */
class AvoidStackEntry {
  uiContext: UIContext;
  modes: KeyboardAvoidMode[];

  constructor(uiContext: UIContext) {
    this.uiContext = uiContext;
    this.modes = [];
  }
}

/**
 * 全局软键盘入口。
 *
 * 典型接入：
 *   EntryAbility.onWindowStageCreate: Keyboard.init(windowStage)
 *   UIExtension 页面 aboutToAppear:  Keyboard.attach(this.getUIContext())
 *   任意位置:                        Keyboard.dismiss() / Keyboard.requestFocus('inputId')
 */
export class Keyboard {
  private static windowStage: window.WindowStage | undefined = undefined;
  private static mainContext: UIContext | undefined = undefined;
  private static attached: AttachedContext[] = [];
  private static avoidStacks: AvoidStackEntry[] = [];
  private static warned: boolean = false;

  /**
   * 主 UIAbility 在 `onWindowStageCreate` 调用一次。
   * 重复调用（接续恢复 / 窗口重建）会替换 stage 并清空旧窗口缓存与避让栈。
   */
  static init(windowStage: window.WindowStage): void {
    Keyboard.windowStage = windowStage;
    Keyboard.mainContext = undefined;
    Keyboard.avoidStacks = [];
    Keyboard.warned = false;
  }

  /**
   * 手动挂载一个 UIContext（UIExtensionAbility 页面等没有 windowStage 的场景）。
   * 后挂载者优先；同一个 UIContext 重复挂载只累计引用计数。
   */
  static attach(uiContext: UIContext): void {
    for (let i = 0; i < Keyboard.attached.length; i += 1) {
      if (Keyboard.attached[i].uiContext === uiContext) {
        Keyboard.attached[i].count += 1;
        return;
      }
    }
    Keyboard.attached.push(new AttachedContext(uiContext, 1));
    Keyboard.warned = false;
  }

  /** 移除之前挂载的 UIContext；引用计数归零才真正移除，并清掉它的避让栈。 */
  static detach(uiContext: UIContext): void {
    for (let i = Keyboard.attached.length - 1; i >= 0; i -= 1) {
      if (Keyboard.attached[i].uiContext === uiContext) {
        Keyboard.attached[i].count -= 1;
        if (Keyboard.attached[i].count <= 0) {
          Keyboard.attached.splice(i, 1);
          Keyboard.removeAvoidStack(uiContext);
        }
        return;
      }
    }
  }

  /** Ability 销毁时清理全部缓存。 */
  static release(): void {
    Keyboard.windowStage = undefined;
    Keyboard.mainContext = undefined;
    Keyboard.attached = [];
    Keyboard.avoidStacks = [];
    Keyboard.warned = false;
  }

  /** 收起软键盘：清掉当前输入焦点。 */
  static dismiss(): void {
    const context: UIContext | undefined = Keyboard.resolveContext();
    if (context === undefined) {
      Keyboard.warnNoContext('dismiss');
      return;
    }
    Keyboard.dismissIn(context);
  }

  /** 在指定 UIContext 上收起软键盘（多窗口 / 特殊场景显式指定）。 */
  static dismissIn(uiContext: UIContext): void {
    try {
      uiContext.getFocusController().clearFocus();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'clearFocus failed: %{public}d', error.code);
    }
  }

  /** 请求指定组件的焦点（组件需已设置 `.id(componentId)`）。 */
  static requestFocus(componentId: string): void {
    const context: UIContext | undefined = Keyboard.resolveContext();
    if (context === undefined) {
      Keyboard.warnNoContext('requestFocus');
      return;
    }
    Keyboard.requestFocusIn(context, componentId);
  }

  /** 在指定 UIContext 上请求组件焦点。 */
  static requestFocusIn(uiContext: UIContext, componentId: string): void {
    try {
      uiContext.getFocusController().requestFocus(componentId);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'requestFocus failed: %{public}d', error.code);
    }
  }

  /** 便捷入口：压入一次 RESIZE 避让模式，必须与 popAvoidMode() 成对调用。 */
  static avoidResize(uiContext?: UIContext): void {
    Keyboard.pushAvoidMode(KeyboardAvoidMode.RESIZE, uiContext);
  }

  /**
   * 压入一次键盘避让模式：先记住当前模式，再设置新模式。
   * 同一 UIContext 可嵌套多次，pop 时按后进先出恢复。
   */
  static pushAvoidMode(mode: KeyboardAvoidMode, uiContext?: UIContext): void {
    const context: UIContext | undefined = uiContext === undefined ? Keyboard.resolveContext() : uiContext;
    if (context === undefined) {
      Keyboard.warnNoContext('pushAvoidMode');
      return;
    }
    Keyboard.ensureAvoidStack(context);
    const entry: AvoidStackEntry | undefined = Keyboard.findAvoidStack(context);
    if (entry === undefined) {
      return;
    }
    try {
      const previous: KeyboardAvoidMode = context.getKeyboardAvoidMode();
      context.setKeyboardAvoidMode(mode);
      entry.modes.push(previous);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'pushAvoidMode failed: %{public}d', error.code);
    }
  }

  /** 恢复上一次避让模式；没有可恢复项时静默返回。 */
  static popAvoidMode(uiContext?: UIContext): void {
    const context: UIContext | undefined = uiContext === undefined ? Keyboard.resolveContext() : uiContext;
    if (context === undefined) {
      Keyboard.warnNoContext('popAvoidMode');
      return;
    }
    const entry: AvoidStackEntry | undefined = Keyboard.findAvoidStack(context);
    if (entry === undefined || entry.modes.length === 0) {
      return;
    }
    const previous: KeyboardAvoidMode | undefined = entry.modes.pop();
    if (previous === undefined) {
      return;
    }
    try {
      context.setKeyboardAvoidMode(previous);
    } catch (err) {
      entry.modes.push(previous);
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'popAvoidMode failed: %{public}d', error.code);
    }
  }

  /** 已挂载上下文优先，其次主窗口，最后尝试从 windowStage 惰性解析。 */
  private static resolveContext(): UIContext | undefined {
    if (Keyboard.attached.length > 0) {
      return Keyboard.attached[Keyboard.attached.length - 1].uiContext;
    }
    if (Keyboard.mainContext !== undefined) {
      return Keyboard.mainContext;
    }
    const stage: window.WindowStage | undefined = Keyboard.windowStage;
    if (stage === undefined) {
      return undefined;
    }
    try {
      Keyboard.mainContext = stage.getMainWindowSync().getUIContext();
      return Keyboard.mainContext;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getMainWindowSync failed: %{public}d', error.code);
      return undefined;
    }
  }

  private static ensureAvoidStack(uiContext: UIContext): void {
    if (Keyboard.findAvoidStack(uiContext) === undefined) {
      Keyboard.avoidStacks.push(new AvoidStackEntry(uiContext));
    }
  }

  private static findAvoidStack(uiContext: UIContext): AvoidStackEntry | undefined {
    for (let i = 0; i < Keyboard.avoidStacks.length; i += 1) {
      if (Keyboard.avoidStacks[i].uiContext === uiContext) {
        return Keyboard.avoidStacks[i];
      }
    }
    return undefined;
  }

  private static removeAvoidStack(uiContext: UIContext): void {
    for (let i = Keyboard.avoidStacks.length - 1; i >= 0; i -= 1) {
      if (Keyboard.avoidStacks[i].uiContext === uiContext) {
        Keyboard.avoidStacks.splice(i, 1);
      }
    }
  }

  private static warnNoContext(action: string): void {
    if (Keyboard.warned) {
      return;
    }
    Keyboard.warned = true;
    hilog.warn(DOMAIN, TAG,
      'no UIContext for %{public}s; call Keyboard.init(windowStage) or Keyboard.attach(uiContext) first', action);
  }
}
