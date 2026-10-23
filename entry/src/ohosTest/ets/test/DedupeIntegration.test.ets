/*
 * DedupeIntegration.test.ets — 跨源去重的存储层集成验证（删除主条 → 提升新主条）。
 *
 * 覆盖 UI 验证无法完成的部分（模拟器弹窗不接受注入触摸）：
 *   1) 两个源收录同一 URL → 后入库者挂靠先入库者；
 *   2) 组内已读同步；
 *   3) 删除主条后，组内另一篇提升为主条且仍可读取；
 *   4) 清理测试数据。
 *
 * 注意：该用例会写入真实应用库（测试 HAP 覆盖主包），结束后在 finally 中删除测试文章。
 */

import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { articleStore } from '../../../main/ets/service/ArticleStore';
import { dedupeService } from '../../../main/ets/service/DedupeService';
import { Article } from '../../../main/ets/model/Feed';
import { TestContext } from './TestContext';

export default function dedupeIntegrationTest() {
  describe('DedupeIntegration', () => {
    it('delete_canonical_promotes_member', 0, async () => {
      const injected: common.UIAbilityContext | undefined = TestContext.value;
      const context: common.Context = injected !== undefined
        ? injected
        : abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      await articleStore.open(context);

      const stamp: string = Date.now().toString();
      const feedA: string = 'dedupe_test_a_' + stamp;
      const feedB: string = 'dedupe_test_b_' + stamp;
      const link: string = 'https://example.com/dedupe/' + stamp;
      const idA: string = feedA + '|' + link;
      const idB: string = feedB + '|' + link;
      const now: number = Date.now();

      try {
        const a: Article = new Article(idA, feedA, 'Dedupe A', 'Dedupe A title', link,
          'summary a', 'content a', now, '', 'tester');
        const b: Article = new Article(idB, feedB, 'Dedupe B', 'Dedupe B title', link,
          'summary b', 'content b', now - 1000, '', 'tester');
        articleStore.insertNew([a, b]);

        const loadedB: Article | undefined = await articleStore.loadById(idB);
        expect(loadedB !== undefined).assertTrue();
        if (loadedB === undefined) {
          return;
        }
        expect(loadedB.canonicalId).assertEqual(idA);

        // 组内已读同步
        await dedupeService.applyRead([idA], true);
        const readA: Article | undefined = await articleStore.loadById(idA);
        const readB: Article | undefined = await articleStore.loadById(idB);
        expect(readA !== undefined && readA.read).assertTrue();
        expect(readB !== undefined && readB.read).assertTrue();

        // 删除主条 → 另一篇提升为主条
        articleStore.deleteMany([idA]);
        const promoted: Article | undefined = await articleStore.loadById(idB);
        expect(promoted !== undefined).assertTrue();
        if (promoted !== undefined) {
          expect(promoted.canonicalId).assertEqual('');
          expect(promoted.read).assertTrue();
        }
        const gone: Article | undefined = await articleStore.loadById(idA);
        expect(gone === undefined).assertTrue();
      } finally {
        articleStore.deleteMany([idA, idB]);
      }
    });
  });
}
