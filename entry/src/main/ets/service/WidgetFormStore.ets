/*
 * WidgetFormStore.ets — 记住已添加的桌面卡片 formId。
 *
 * 卡片提供方在 onAddForm / onRemoveForm 维护；主应用改主题色时按这些 id 定向
 * 调用 formProvider.updateForm，不必等 30 分钟周期刷新。
 * 只存 formId，不含用户数据，因此不进入备份白名单。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';

/** 防止偏好库无限增长：正常用户不会同时挂这么多卡片。 */
const MAX_FORM_IDS: number = 50;

export class WidgetFormStore {
  private static async read(context: common.Context): Promise<string[]> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
      const raw: string = store.getSync(PreferencesConstants.KEY_WIDGET_FORM_IDS, '[]') as string;
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) {
        return [];
      }
      const values: Object[] = parsed as Object[];
      const result: string[] = [];
      for (let i = 0; i < values.length && result.length < MAX_FORM_IDS; i += 1) {
        if (typeof values[i] === 'string' && (values[i] as string).length > 0 &&
          result.indexOf(values[i] as string) < 0) {
          result.push(values[i] as string);
        }
      }
      return result;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('WidgetFormStore.read failed: ' + error.code.toString());
      return [];
    }
  }

  private static async write(context: common.Context, ids: string[]): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
      store.putSync(PreferencesConstants.KEY_WIDGET_FORM_IDS, JSON.stringify(ids));
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('WidgetFormStore.write failed: ' + error.code.toString());
    }
  }

  /** 登记一张新卡片。 */
  static async add(context: common.Context, formId: string): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    const ids: string[] = await WidgetFormStore.read(context);
    if (ids.indexOf(formId) >= 0) {
      return;
    }
    ids.push(formId);
    await WidgetFormStore.write(context, ids.slice(0, MAX_FORM_IDS));
  }

  /** 卡片被移除。 */
  static async remove(context: common.Context, formId: string): Promise<void> {
    const ids: string[] = await WidgetFormStore.read(context);
    const index: number = ids.indexOf(formId);
    if (index < 0) {
      return;
    }
    ids.splice(index, 1);
    await WidgetFormStore.write(context, ids);
  }

  /** 当前所有卡片 id（拷贝）。 */
  static async list(context: common.Context): Promise<string[]> {
    return WidgetFormStore.read(context);
  }
}
