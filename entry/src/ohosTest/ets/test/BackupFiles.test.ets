import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { TestContext } from './TestContext';
import { deleteSnapshot, readSnapshot, writeSnapshot } from '../../../main/ets/service/BackupFiles';

export default function backupFilesTest() {
  describe('BackupFiles', () => {
    it('async_snapshot_roundtrip_preserves_unicode', 0, async () => {
      const injected: common.UIAbilityContext | undefined = TestContext.value;
      const context: common.Context = injected !== undefined
        ? injected : abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const content: string = '{"text":"中文🙂"}' + '一二三abc'.repeat(16000);
      const name: string = 'perf-test-' + Date.now() + '.json';
      const path: string = await writeSnapshot(context, name, content);
      expect(path.length > 0).assertTrue();
      try {
        expect(await readSnapshot(path)).assertEqual(content);
      } finally {
        expect(await deleteSnapshot(path)).assertTrue();
      }
    });
  });
}
