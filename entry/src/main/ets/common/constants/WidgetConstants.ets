/*
 * WidgetConstants.ets — 服务卡片（桌面卡片）的共享常量。
 *
 * 卡片 UI（form/RssWidgetCard.ets）与卡片提供方（form/RssWidgetAbility.ets）都要用，
 * 而且要保证「推送数据的 key」与「卡片 @Local 变量名」完全一致，所以集中在这里定义。
 */

export class WidgetConstants {
  /** 卡片数据里表示尺寸的 key；必须与卡片里 @Local dimension 的变量名同名。 */
  static readonly KEY_DIMENSION: string = 'dimension';
  /** 未读数字段的 key；与卡片 @Local unread 同名。 */
  static readonly KEY_UNREAD: string = 'unread';
  /** 前三条标题的 key；与卡片 @Local t1/t2/t3 同名。 */
  static readonly KEY_TITLE_PREFIX: string = 't';

  /** 小卡片（2*2）：只放未读数 + 1 条标题。 */
  static readonly DIMENSION_SMALL: string = 'small';
  /** 大卡片（2*4 及更大）：未读数 + 最多 3 条标题。 */
  static readonly DIMENSION_LARGE: string = 'large';

  /** 小卡片展示的标题条数。 */
  static readonly SMALL_TITLE_COUNT: number = 1;
  /** 大卡片展示的标题条数。 */
  static readonly LARGE_TITLE_COUNT: number = 3;
}
