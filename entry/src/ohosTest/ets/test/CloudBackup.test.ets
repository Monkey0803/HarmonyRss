/*
 * CloudBackup.test.ets — 用户云空间（端云文件协同）读写单测。
 *
 * 只能在真机跑：设备不支持云空间时静默跳过写入用例（不报失败），
 * 支持时用测试专用文件名写入 → 读回 → 校验元信息 → 删除，不污染用户云备份。
 */

import { describe, it, expect } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import {
  CloudBackupInfo,
  cloudBackupInfo,
  readCloudBackup,
  writeCloudBackup
} from '../../../main/ets/service/BackupFiles';
import { TestContext } from './TestContext';

const TEST_FILE: string = 'harmonyrss-cloud-backup.test.json';
const CONTENT: string = '{"version":1,"kind":"test"}';

export default function cloudBackupTest(): void {
  describe('CloudBackup', () => {
    it('write_read_roundtrip_in_cloud_dir', 0, async () => {
      const context: common.UIAbilityContext | undefined = TestContext.value;
      if (context === undefined) {
        return;
      }
      const info: CloudBackupInfo = cloudBackupInfo(context);
      if (!info.available) {
        // 设备 / 系统不支持端云文件协同：跳过写入，只要求不抛异常。
        return;
      }
      const path: string = context.cloudFileDir + '/' + TEST_FILE;
      try {
        fileIo.unlinkSync(path);
      } catch (err) {
        // 文件本来就不存在。
      }
      expect(writeCloudBackup(context, CONTENT, TEST_FILE)).assertTrue();
      expect(readCloudBackup(context, TEST_FILE)).assertEqual(CONTENT);
      const written: CloudBackupInfo = cloudBackupInfo(context, TEST_FILE);
      expect(written.exists).assertTrue();
      expect(written.bytes > 0).assertTrue();
      try {
        fileIo.unlinkSync(path);
      } catch (err) {
        // 清理失败不影响断言。
      }
    });

    it('missing_file_reads_empty', 0, () => {
      const context: common.UIAbilityContext | undefined = TestContext.value;
      if (context === undefined) {
        return;
      }
      expect(readCloudBackup(context, 'harmonyrss-missing-test.json')).assertEqual('');
    });
  });
}
