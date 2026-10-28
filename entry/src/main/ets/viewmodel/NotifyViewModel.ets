/*
 * NotifyViewModel.ets — 通知设置页的状态与动作（@ObservedV2）。
 *
 * 状态是「编辑中的策略」，save() 时一次性写进 NotifyStore + SettingsStore；
 * 关键词的归一规则（trim / 大小写不敏感去重 / ≤20）复用 NotifyPolicy，避免设置页与后台判定漂移。
 */

import { common } from '@kit.AbilityKit';
import { CommonConstants } from '../common/constants/CommonConstants';
import { NotifyDefaults, NotifyPolicy } from '../model/Notify';
import { clampDigestHour, clampMinuteOfDay, normalizeKeywords, normalizePolicy } from '../service/NotifyPolicy';
import { notifyStore } from '../service/NotifyStore';
import { notifyService } from '../service/NotifyService';
import { settingsStore } from '../service/SettingsStore';

@ObservedV2
export class NotifyViewModel {
  /** 当前编辑中的策略快照（与下面的分散字段保持同步，方便偏好读写直接复用）。 */
  @Trace policy: NotifyPolicy = new NotifyPolicy();
  /** 免打扰开关。 */
  @Trace dndEnabled: boolean = NotifyDefaults.DND_ENABLED;
  /** 免打扰开始（当天第几分钟）。 */
  @Trace dndStart: number = NotifyDefaults.DND_START;
  /** 免打扰结束（当天第几分钟）。 */
  @Trace dndEnd: number = NotifyDefaults.DND_END;
  /** 每日摘要开关。 */
  @Trace digestEnabled: boolean = NotifyDefaults.DIGEST_ENABLED;
  /** 每日摘要小时（0–23）。 */
  @Trace digestHour: number = NotifyDefaults.DIGEST_HOUR;
  /** 关键词列表（展示用，已归一）。 */
  @Trace keywords: string[] = [];
  /** 系统通知授权状态。 */
  @Trace authorized: boolean = false;
  /** 保存中（防重复点击 / 展示 loading）。 */
  @Trace saving: boolean = false;

  /** 首次装配完成的信号（设置页可 await，避免闪一下默认值）。 */
  private ready: Promise<void> = Promise.resolve();

  /** 打开通知偏好库 + 设置库，读出策略与系统授权状态。 */
  init(context: common.Context): void {
    this.ready = this.load(context);
  }

  /** 等待首次装配完成（未 init 时立即返回）。 */
  async whenReady(): Promise<void> {
    await this.ready;
  }

  private async load(context: common.Context): Promise<void> {
    await notifyStore.open(context);
    await settingsStore.load(context);
    this.applyPolicy(notifyStore.loadPolicy());
    this.refreshPermission();
  }

  /**
   * 重新读取系统授权状态。
   * 设置页在 aboutToAppear / 申请授权返回 / 从系统设置回来点「重新检查」时调用。
   */
  refreshPermission(): void {
    this.authorized = notifyService.isEnabled();
  }

  /** 把策略对象拆到各 @Trace 字段（保证视图与 save 用的值一致）。 */
  private applyPolicy(policy: NotifyPolicy): void {
    const normalized: NotifyPolicy = normalizePolicy(policy);
    this.policy = normalized;
    this.dndEnabled = normalized.dndEnabled;
    this.dndStart = normalized.dndStart;
    this.dndEnd = normalized.dndEnd;
    this.digestEnabled = normalized.digestEnabled;
    this.digestHour = normalized.digestHour;
    this.keywords = normalized.keywords.slice();
  }

  /** 各 setter 只改内存；落盘由 save() 统一完成（避免拖动时间时频繁写库）。 */
  private syncPolicy(): void {
    this.policy = normalizePolicy(new NotifyPolicy(
      this.dndEnabled, this.dndStart, this.dndEnd,
      this.digestEnabled, this.digestHour, this.keywords));
  }

  setDndEnabled(value: boolean): void {
    this.dndEnabled = value;
    this.syncPolicy();
  }

  /** 起止相同视为关闭（由 NotifyPolicy.inDnd 处理），这里只做范围归一。 */
  setDndRange(start: number, end: number): void {
    this.dndStart = clampMinuteOfDay(start, this.dndStart);
    this.dndEnd = clampMinuteOfDay(end, this.dndEnd);
    this.syncPolicy();
  }

  setDigestEnabled(value: boolean): void {
    this.digestEnabled = value;
    this.syncPolicy();
  }

  setDigestHour(hour: number): void {
    this.digestHour = clampDigestHour(hour, this.digestHour);
    this.syncPolicy();
  }

  /**
   * 添加关键词：trim → 空串忽略 → 大小写不敏感去重 → 上限 20。
   * 返回是否真的添加（界面可据此提示「已存在 / 已达上限」）。
   */
  addKeyword(text: string): boolean {
    const trimmed: string = text.trim();
    if (trimmed.length === 0 || this.keywords.length >= CommonConstants.NOTIFY_KEYWORD_MAX) {
      return false;
    }
    const key: string = trimmed.toLowerCase();
    for (let i = 0; i < this.keywords.length; i += 1) {
      if (this.keywords[i].toLowerCase() === key) {
        return false;
      }
    }
    const next: string[] = this.keywords.slice();
    next.push(trimmed);
    this.keywords = normalizeKeywords(next);
    this.syncPolicy();
    return true;
  }

  /** 删除关键词（大小写不敏感匹配）；返回是否删掉。 */
  removeKeyword(text: string): boolean {
    const key: string = text.trim().toLowerCase();
    if (key.length === 0) {
      return false;
    }
    const next: string[] = [];
    let removed: boolean = false;
    for (let i = 0; i < this.keywords.length; i += 1) {
      if (this.keywords[i].toLowerCase() === key) {
        removed = true;
      } else {
        next.push(this.keywords[i]);
      }
    }
    if (!removed) {
      return false;
    }
    this.keywords = next;
    this.syncPolicy();
    return true;
  }

  /** 申请通知授权（系统会弹一次授权框）；返回最终状态。 */
  async requestPermission(ability: common.UIAbilityContext): Promise<boolean> {
    const granted: boolean = await notifyService.requestEnable(ability);
    this.authorized = granted;
    return granted;
  }

  /** 发送测试通知；返回是否成功（失败时界面提示，不抛错）。 */
  async test(ability: common.UIAbilityContext): Promise<boolean> {
    return await notifyService.testNotification(ability);
  }

  /**
   * 保存策略：NotifyStore 同时写偏好库与 appSettings（下一次抓取立即生效）；
   * SettingsStore.save() 兜底全量落盘。NotifyStore 的写方法是同步 void，不 await。
   */
  save(): void {
    this.saving = true;
    try {
      this.syncPolicy();
      notifyStore.savePolicy(this.policy);
      settingsStore.save();
      this.applyPolicy(notifyStore.loadPolicy());
    } finally {
      this.saving = false;
    }
  }
}

/** 全局唯一 ViewModel。 */
export const notifyViewModel: NotifyViewModel = new NotifyViewModel();
