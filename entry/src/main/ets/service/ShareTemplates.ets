/*
 * ShareTemplates.ets — 自定义分享模板的渲染、校验与持久化。
 *
 * 渲染 / 校验是纯函数（可单测）；持久化走 preferences（KEY_SHARE_TEMPLATES，JSON 数组），
 * 与现有 FeedStore / SettingsStore 的方式一致：读出来逐条做类型校验，脏数据直接丢弃。
 *
 * 设计要点：
 *   - 占位符固定集合 {title} {url} {summary} {author} {tags}；未知占位符原样保留。
 *   - 首次使用（偏好库没有该 key）返回默认模板，但**不落库** —— 用户没编辑就不写。
 *   - 用户把模板全部删掉时落盘 `[]`，之后 list() 如实返回空数组，不再塞默认模板。
 *   - sort 在 saveAll 时按数组下标重排，保证顺序连续、无重复。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';
import { CommonConstants } from '../common/constants/CommonConstants';
import { ShareContext, ShareTemplate } from '../model/Share';

/** 落盘用的扁平结构。 */
interface TemplateRecord {
  id: string;
  name: string;
  content: string;
  sort: number;
}

/** 默认模板 id（不落库，仅用于展示）。 */
const DEFAULT_TEMPLATE_ID: string = 'tpl_default';

/** 生成稳定 id：时间戳 + 随机后缀（同一毫秒内多次创建也不会撞）。 */
function newId(): string {
  return 'tpl_' + Date.now() + '_' + Math.floor(Math.random() * 1000000);
}

/** 解码模板数组（纯函数）：非法项直接丢弃，sort 统一归一为整数。 */
export function decodeTemplates(text: string): ShareTemplate[] {
  const result: ShareTemplate[] = [];
  if (text.length === 0) {
    return result;
  }
  try {
    const records: TemplateRecord[] = JSON.parse(text) as TemplateRecord[];
    for (let i = 0; i < records.length; i += 1) {
      const record: TemplateRecord = records[i];
      const id: string = typeof record.id === 'string' ? record.id : '';
      const name: string = typeof record.name === 'string' ? record.name : '';
      const content: string = typeof record.content === 'string' ? record.content : '';
      if (id.length === 0 || name.length === 0 || content.length === 0) {
        continue;
      }
      const sort: number = typeof record.sort === 'number' && record.sort >= 0
        ? Math.round(record.sort)
        : result.length;
      result.push(new ShareTemplate(id, name, content, sort));
    }
  } catch (err) {
    // JSON.parse 抛的是 SyntaxError，没有 BusinessError.code；只记录消息。
    const error: BusinessError = err as BusinessError;
    const detail: string = error.message !== undefined ? error.message : 'invalid json';
    console.error('ShareTemplates.decode failed: ' + detail);
  }
  return result;
}

/** 编码模板数组（纯函数）：按当前顺序重排 sort。 */
export function encodeTemplates(items: ShareTemplate[]): string {
  const records: TemplateRecord[] = [];
  for (let i = 0; i < items.length; i += 1) {
    const item: ShareTemplate = items[i];
    const record: TemplateRecord = {
      id: item.id,
      name: item.name,
      content: item.content,
      sort: i
    };
    records.push(record);
  }
  return JSON.stringify(records);
}

/** 按 sort 升序排序（同 sort 保持原顺序）。纯函数。 */
export function sortTemplates(items: ShareTemplate[]): ShareTemplate[] {
  const copy: ShareTemplate[] = items.slice();
  copy.sort((a: ShareTemplate, b: ShareTemplate) => a.sort - b.sort);
  return copy;
}

/**
 * 渲染模板：占位符全量替换；`{tags}` 用 ", " 连接；未知占位符原样保留。
 * 纯函数（可单测）。
 */
export function render(template: ShareTemplate, ctx: ShareContext): string {
  return template.content
    .split('{title}').join(ctx.title)
    .split('{url}').join(ctx.url)
    .split('{summary}').join(ctx.summary)
    .split('{author}').join(ctx.author)
    .split('{tags}').join(ctx.tags.join(', '));
}

/** 校验名称 / 内容：返回错误资源 key，空串表示通过。纯函数（可单测）。 */
export function validate(name: string, content: string): string {
  if (name.trim().length === 0) {
    return 'tpl_err_name_empty';
  }
  if (name.length > CommonConstants.SHARE_TEMPLATE_NAME_MAX) {
    return 'tpl_err_name_long';
  }
  if (content.trim().length === 0) {
    return 'tpl_err_content_empty';
  }
  if (content.length > CommonConstants.SHARE_TEMPLATE_CONTENT_MAX) {
    return 'tpl_err_content_long';
  }
  return '';
}

/** 默认模板（{title} 换行 {url}），首次使用且未落库时展示。 */
export function defaultTemplate(): ShareTemplate {
  return new ShareTemplate(DEFAULT_TEMPLATE_ID, 'Default', '{title}\n{url}', 0);
}

export class ShareTemplates {
  private store: preferences.Preferences | undefined = undefined;
  /** 默认模板显示名（open 后按当前语言取资源，取不到退回 Default）。 */
  private defaultName: string = 'Default';

  /** 打开偏好库（宿主启动或首次打开面板时调用）。 */
  async open(context: common.Context): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('ShareTemplates.open failed: ' + error.code.toString());
    }
    try {
      this.defaultName = context.resourceManager.getStringSync($r('app.string.tpl_default_name').id);
    } catch (err) {
      // 资源缺失时保留英文兜底，不影响功能。
    }
  }

  /** 面板展示用列表：无落库数据时返回默认模板（不落库）；否则按 sort 升序。 */
  async list(): Promise<ShareTemplate[]> {
    const stored: ShareTemplate[] = this.loadStored();
    if (stored.length > 0) {
      return sortTemplates(stored);
    }
    if (!this.hasStoredValue()) {
      const fallback: ShareTemplate = defaultTemplate();
      fallback.name = this.defaultName;
      return [fallback];
    }
    return [];
  }

  /** 全量写回（顺序即展示顺序，sort 自动重排）。 */
  async saveAll(items: ShareTemplate[]): Promise<boolean> {
    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return false;
    }
    try {
      store.putSync(PreferencesConstants.KEY_SHARE_TEMPLATES, encodeTemplates(items));
      await store.flush();
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('ShareTemplates.saveAll failed: ' + error.code.toString());
      return false;
    }
  }

  /**
   * 新建模板：名称 / 内容非法或已达上限时返回 undefined（调用方先用 validate 取错误 key）。
   * 注意这里基于「落库内容」而非 list()：没有落库时不会把默认模板一起写进去。
   */
  async create(name: string, content: string): Promise<ShareTemplate | undefined> {
    if (validate(name, content).length > 0) {
      return undefined;
    }
    const stored: ShareTemplate[] = this.loadStored();
    if (stored.length >= CommonConstants.SHARE_TEMPLATE_MAX) {
      return undefined;
    }
    const created: ShareTemplate = new ShareTemplate(newId(), name.trim(), content, stored.length);
    stored.push(created);
    const saved: boolean = await this.saveAll(stored);
    return saved ? created : undefined;
  }

  /** 更新模板：找不到 / 非法返回 false。 */
  async update(id: string, name: string, content: string): Promise<boolean> {
    if (validate(name, content).length > 0) {
      return false;
    }
    const stored: ShareTemplate[] = this.loadStored();
    for (let i = 0; i < stored.length; i += 1) {
      if (stored[i].id === id) {
        stored[i].name = name.trim();
        stored[i].content = content;
        return await this.saveAll(stored);
      }
    }
    return false;
  }

  /** 删除模板；成功返回 true。 */
  async remove(id: string): Promise<boolean> {
    const stored: ShareTemplate[] = this.loadStored();
    const kept: ShareTemplate[] = stored.filter((item: ShareTemplate) => item.id !== id);
    if (kept.length === stored.length) {
      return false;
    }
    return await this.saveAll(kept);
  }

  /** 上移 / 下移（delta = -1 / +1）；越界时不动，返回 false。 */
  async move(id: string, delta: number): Promise<boolean> {
    const ordered: ShareTemplate[] = sortTemplates(this.loadStored());
    let index: number = -1;
    for (let i = 0; i < ordered.length; i += 1) {
      if (ordered[i].id === id) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      return false;
    }
    const target: number = index + (delta < 0 ? -1 : 1);
    if (target < 0 || target >= ordered.length || delta === 0) {
      return false;
    }
    const moved: ShareTemplate = ordered[index];
    ordered.splice(index, 1);
    ordered.splice(target, 0, moved);
    return await this.saveAll(ordered);
  }

  /** 读取落库模板（未 open / 解析失败时为空数组）。 */
  private loadStored(): ShareTemplate[] {
    const text: string = this.readRaw();
    return decodeTemplates(text);
  }

  /** 偏好库里是否已有这个 key（区分「首次使用」与「用户删光」）。 */
  private hasStoredValue(): boolean {
    return this.readRaw().length > 0;
  }

  private readRaw(): string {
    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return '';
    }
    try {
      const raw: preferences.ValueType = store.getSync(PreferencesConstants.KEY_SHARE_TEMPLATES, '');
      return typeof raw === 'string' ? raw : '';
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('ShareTemplates.read failed: ' + error.code.toString());
      return '';
    }
  }
}

/** 全局唯一实例。 */
export const shareTemplates: ShareTemplates = new ShareTemplates();
