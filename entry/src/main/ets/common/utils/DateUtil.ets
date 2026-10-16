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

  private static pad(value: number, length: number): string {
    let text: string = value.toString();
    while (text.length < length) {
      text = '0' + text;
    }
    return text;
  }
}
