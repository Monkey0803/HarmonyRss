/*
 * DateUtil.ets — 纯逻辑的时间格式化（与 UI 无关，可被任何层引用）。
 *
 * 这里只做「时间戳 → 稳定字符串」的确定性转换；分隔符属于格式逻辑，不是界面文案。
 */
export class DateUtil {
  /** yyyy-MM-dd HH:mm；时间戳非法时返回空串。 */
  static format(timestamp: number): string {
    if (timestamp <= 0) {
      return '';
    }
    const date: Date = new Date(timestamp);
    const parts: string[] = [
      DateUtil.pad(date.getFullYear(), 4),
      DateUtil.pad(date.getMonth() + 1, 2),
      DateUtil.pad(date.getDate(), 2)
    ];
    const clock: string[] = [
      DateUtil.pad(date.getHours(), 2),
      DateUtil.pad(date.getMinutes(), 2)
    ];
    return parts.join('-') + ' ' + clock.join(':');
  }

  /**
   * 列表行用的紧凑时间：今天 → HH:mm；今年 → MM-dd HH:mm；更早 → yyyy-MM-dd。
   * 纯数字格式，不依赖语言；完整时间仍由 format() 提供给无障碍文案。
   */
  static formatShort(timestamp: number, now: number = Date.now()): string {
    if (timestamp <= 0) {
      return '';
    }
    const date: Date = new Date(timestamp);
    const current: Date = new Date(now);
    const clock: string = DateUtil.pad(date.getHours(), 2) + ':' + DateUtil.pad(date.getMinutes(), 2);
    if (date.getFullYear() === current.getFullYear() && date.getMonth() === current.getMonth() &&
      date.getDate() === current.getDate()) {
      return clock;
    }
    if (date.getFullYear() === current.getFullYear()) {
      return DateUtil.pad(date.getMonth() + 1, 2) + '-' + DateUtil.pad(date.getDate(), 2) + ' ' + clock;
    }
    return DateUtil.pad(date.getFullYear(), 4) + '-' + DateUtil.pad(date.getMonth() + 1, 2) + '-' +
      DateUtil.pad(date.getDate(), 2);
  }

  /** HH:mm（表头显示「最近同步」用）；时间戳非法时返回空串。 */
  static clock(timestamp: number): string {
    if (timestamp <= 0) {
      return '';
    }
    const date: Date = new Date(timestamp);
    return DateUtil.pad(date.getHours(), 2) + ':' + DateUtil.pad(date.getMinutes(), 2);
  }

  private static pad(value: number, length: number): string {
    let text: string = value.toString();
    while (text.length < length) {
      text = '0' + text;
    }
    return text;
  }
}
