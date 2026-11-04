import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { TestContext } from './TestContext';
import { ArticleDbConstants } from '../../../main/ets/common/constants/RssConstants';
import { ArticleRepository } from '../../../main/ets/service/ArticleRepository';
import { Article } from '../../../main/ets/model/Feed';

export default function articleMigrationTest() {
  describe('ArticleMigration', () => {
    it('repairs_missing_columns_even_with_current_schema_version', 0, async () => {
      const injected: common.UIAbilityContext | undefined = TestContext.value;
      const context: common.Context = injected !== undefined
        ? injected : abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const name: string = 'migration_' + Date.now() + '.db';
      const config: relationalStore.StoreConfig = {
        name: name,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      let repository: ArticleRepository | undefined = undefined;
      try {
        const old: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
        old.executeSync('CREATE TABLE articles (' +
          'id TEXT PRIMARY KEY, feed_id TEXT NOT NULL, feed_title TEXT NOT NULL DEFAULT \'\',' +
          'title TEXT NOT NULL DEFAULT \'\', link TEXT NOT NULL DEFAULT \'\',' +
          'summary TEXT NOT NULL DEFAULT \'\', content TEXT NOT NULL DEFAULT \'\',' +
          'published_at INTEGER NOT NULL DEFAULT 0, is_read INTEGER NOT NULL DEFAULT 0,' +
          'is_starred INTEGER NOT NULL DEFAULT 0, fetched_at INTEGER NOT NULL DEFAULT 0)');
        old.executeSync('INSERT INTO articles (id, feed_id, title) VALUES (?,?,?)',
          ['migration_1', 'feed_1', 'preserved']);
        old.version = ArticleDbConstants.SCHEMA_VERSION;
        old.close();

        repository = new ArticleRepository(name);
        await repository.open(context);
        const rows: Article[] = await repository.loadForList();
        expect(rows.length).assertEqual(1);
        expect(rows[0].title).assertEqual('preserved');
        expect(rows[0].duplicateCount).assertEqual(1);
        const store: relationalStore.RdbStore | undefined = repository.getStore();
        expect(store !== undefined).assertTrue();
        if (store !== undefined) {
          const columns: relationalStore.ResultSet = store.querySqlSync('PRAGMA table_info(articles)');
          let repaired: boolean = false;
          try {
            while (columns.goToNextRow()) {
              if (columns.getString(columns.getColumnIndex('name')) === 'media_progress') {
                repaired = true;
              }
            }
          } finally {
            columns.close();
          }
          expect(repaired).assertTrue();
        }
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 700));
      } finally {
        repository?.getStore()?.close();
        await relationalStore.deleteRdbStore(context, name);
      }
    });
  });
}
