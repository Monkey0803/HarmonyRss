/*
 * DateUtil.test.ets — 紧凑时间格式的边界单测。
 */

import { describe, it, expect } from '@ohos/hypium';
import { DateUtil } from '../../../main/ets/common/utils/DateUtil';

export default function dateUtilTest() {
  describe('DateUtil', () => {
    it('invalid_timestamp_is_empty', 0, () => {
      expect(DateUtil.formatShort(0)).assertEqual('');
      expect(DateUtil.formatShort(-1)).assertEqual('');
    });

    it('same_day_is_clock_only', 0, () => {
      const now: number = Date.now();
      const text: string = DateUtil.formatShort(now, now);
      expect(text.length).assertEqual(5);
      expect(text.indexOf(':') > 0).assertTrue();
    });

    it('same_year_uses_month_day_and_clock', 0, () => {
      const now: number = new Date(2020, 5, 1, 12, 0, 0).getTime();
      const timestamp: number = new Date(2020, 4, 2, 3, 4, 0).getTime();
      expect(DateUtil.formatShort(timestamp, now).length).assertEqual(11);
    });

    it('older_year_uses_date_only', 0, () => {
      const now: number = new Date(2020, 5, 1, 12, 0, 0).getTime();
      const timestamp: number = new Date(2001, 0, 2, 3, 4, 0).getTime();
      const text: string = DateUtil.formatShort(timestamp, now);
      expect(text.length).assertEqual(10);
      expect(text.indexOf(':') < 0).assertTrue();
    });
  });
}
