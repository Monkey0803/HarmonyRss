/*
 * RssWidgetAbility.ets — 服务卡片的数据供给（FormExtensionAbility）。
 *
 * onAddForm 必须同步返回，所以先给一版占位数据，再异步读本地库把真实数据 updateForm 回卡片；
 * 系统按 form_config.json 的 updateDuration 周期性回调 onUpdateForm，走同一条刷新路径。
 * 只读本地库（不联网）：卡片刷新必须快且省电，联网交给 WorkScheduler 的后台任务。
 *
 * 尺寸适配：form_config.json 声明支持 2*2 与 2*4，两种尺寸的信息量不同。尺寸只能从
 * want.parameters[formInfo.FormParam.DIMENSION_KEY] 拿到（onAddForm / onUpdateForm 的
 * wantParams 各给一次），所以这里按 formId 记住它，并在推送数据里带上 dimension 字段，
 * 卡片按该字段分支布局（key 与卡片 @Local 变量名一致）。
 */

import { formBindingData, formInfo, FormExtensionAbility, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { articleStore, WidgetSnapshot } from '../service/ArticleStore';
import { WidgetConstants } from '../common/constants/WidgetConstants';
import { DateUtil } from '../common/utils/DateUtil';

const DOMAIN: number = 0x0000;
const TAG: string = 'RssWidgetAbility';

export default class RssWidgetAbility extends FormExtensionAbility {
  /**
   * formId → 尺寸语义值。进程重启后会丢，丢失时不下发 dimension 字段 ——
   * 卡片上的 @Local 会保留上一次收到的值，不会被重置成默认。
   */
  private dimensions: Map<string, string> = new Map();

  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = this.formIdOf(want);
    const dimension: string = this.dimensionOf(want.parameters);
    if (dimension.length > 0) {
      this.dimensions.set(formId, dimension);
    }
    // 先回占位，随后立刻用真实数据刷新，避免卡片长时间空白。
    this.refresh(formId);
    return formBindingData.createFormBindingData(this.emptyData(dimension));
  }

  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    // 改尺寸时系统会带上新的尺寸参数；带了就更新记录。
    const dimension: string = this.dimensionOf(wantParams);
    if (dimension.length > 0) {
      this.dimensions.set(formId, dimension);
    }
    this.refresh(formId);
  }

  /**
   * 卡片上的「刷新」按钮走 message 事件：这里重读本地库并推回卡片。
   * 卡片进程不能联网（FormExtensionAbility 与 UIAbility 不是同一个进程），所以这里只刷本地数据；
   * 真正的联网抓取仍由应用自身（打开时 / 自动刷新）与 WorkScheduler 后台任务负责。
   */
  onFormEvent(formId: string, message: string): void {
    try {
      const parsed: Record<string, Object> = JSON.parse(message) as Record<string, Object>;
      const event: Object | undefined = parsed[WidgetConstants.PARAM_EVENT];
      if (typeof event === 'string' && event === WidgetConstants.EVENT_REFRESH) {
        this.refresh(formId);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'onFormEvent parse failed: %{public}d', error.code);
    }
  }

  onRemoveForm(formId: string): void {
    this.dimensions.delete(formId);
    hilog.info(DOMAIN, TAG, 'onRemoveForm: %{public}s', formId);
  }

  /** 读本地库 → 组装数据 → updateForm。 */
  private async refresh(formId: string): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    try {
      const dimension: string = this.dimensionFor(formId);
      const count: number = dimension === WidgetConstants.DIMENSION_SMALL
        ? WidgetConstants.SMALL_TITLE_COUNT
        : WidgetConstants.LARGE_TITLE_COUNT;
      await articleStore.open(this.context);
      const snapshot: WidgetSnapshot = await articleStore.widgetSnapshot(count);
      const data: Record<string, string | number> = this.buildData(snapshot, dimension);
      await formProvider.updateForm(formId, formBindingData.createFormBindingData(data));
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'refresh failed: %{public}d', error.code);
    }
  }

  private buildData(snapshot: WidgetSnapshot, dimension: string): Record<string, string | number> {
    const data: Record<string, string | number> = this.emptyData(dimension);
    const titles: string[] = snapshot.titles;
    data[WidgetConstants.KEY_UNREAD] = snapshot.unread;
    for (let i = 0; i < titles.length; i += 1) {
      const suffix: string = (i + 1).toString();
      data[WidgetConstants.KEY_TITLE_PREFIX + suffix] = titles[i];
      if (i < snapshot.ids.length) {
        data[WidgetConstants.KEY_ID_PREFIX + suffix] = snapshot.ids[i];
      }
    }
    if (snapshot.lastFetchedAt > 0) {
      data[WidgetConstants.KEY_SYNC] = DateUtil.clock(snapshot.lastFetchedAt);
    }
    return data;
  }

  /** 占位 / 基准数据：所有字段都先置空，避免卡片上残留上一次的值。 */
  private emptyData(dimension: string): Record<string, string | number> {
    const data: Record<string, string | number> = {
      'unread': 0,
      't1': '',
      't2': '',
      't3': '',
      'i1': '',
      'i2': '',
      'i3': '',
      'sync': ''
    };
    if (dimension.length > 0) {
      data[WidgetConstants.KEY_DIMENSION] = dimension;
    }
    return data;
  }

  /** 该卡片的尺寸语义值；未知返回空串（此时不下发 dimension）。 */
  private dimensionFor(formId: string): string {
    const known: string | undefined = this.dimensions.get(formId);
    return known === undefined ? '' : known;
  }

  /** 把 want 参数里的 FormDimension 数值转成卡片能直接判断的语义值。 */
  private dimensionOf(params: Record<string, Object> | undefined): string {
    if (params === undefined) {
      return '';
    }
    const raw: Object | undefined = params[formInfo.FormParam.DIMENSION_KEY];
    if (typeof raw !== 'number') {
      return '';
    }
    return raw === formInfo.FormDimension.Dimension_2_2
      ? WidgetConstants.DIMENSION_SMALL
      : WidgetConstants.DIMENSION_LARGE;
  }

  /** 从 want 里取卡片标识；拿不到时返回空串。 */
  private formIdOf(want: Want): string {
    const parameters: Record<string, Object> | undefined = want.parameters;
    if (parameters === undefined) {
      return '';
    }
    const raw: Object | undefined = parameters[formInfo.FormParam.IDENTITY_KEY];
    return typeof raw === 'string' ? raw : '';
  }
}
