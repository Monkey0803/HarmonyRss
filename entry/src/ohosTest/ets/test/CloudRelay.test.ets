/*
 * CloudRelay.test.ets — 云端同步游标与同时间戳分页回归。
 *
 * 用内存后端验证游标，再用独立临时 RDB 验证生产 SQL 的续页条件。
 */

import { describe, it, expect } from '@ohos/hypium';
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { CloudRelayBackend, CloudCursor, encodeCloudCursor, numericCursor,
  parseCloudCursor } from '../../../main/ets/service/sync/CloudRelayBackend';
import { CloudStore, CLOUD_PAGE_SQL, cloudStore } from '../../../main/ets/service/sync/CloudStore';
import { SyncPullPage, SyncRecord } from '../../../main/ets/model/Sync';
import { TestContext } from './TestContext';

class MemoryCloudStore extends CloudStore {
  private readonly rows: SyncRecord[];

  constructor(rows: SyncRecord[]) {
    super();
    this.rows = rows;
  }

  async listSince(cursorTime: number, cursorKey: string, limit: number): Promise<SyncRecord[]> {
    const result: SyncRecord[] = [];
    for (let i = 0; i < this.rows.length && result.length < limit; i += 1) {
      const row: SyncRecord = this.rows[i];
      if (row.updatedAt > cursorTime ||
        (row.updatedAt === cursorTime && row.key > cursorKey)) {
        result.push(row);
      }
    }
    return result;
  }
}

export default function cloudRelayTest(): void {
  describe('CloudRelay', () => {
    it('numericCursor_parses_timestamps', 0, () => {
      expect(numericCursor('1700000000000')).assertEqual(1700000000000);
      expect(numericCursor('1')).assertEqual(1);
    });

    it('numericCursor_rejects_dirty_values', 0, () => {
      expect(numericCursor('')).assertEqual(0);
      expect(numericCursor('abc')).assertEqual(0);
      expect(numericCursor('-5')).assertEqual(0);
      expect(numericCursor('Infinity')).assertEqual(0);
    });

    it('betterCursor_keeps_newer', 0, () => {
      const backend: CloudRelayBackend = new CloudRelayBackend(cloudStore);
      expect(backend.betterCursor('100', '200')).assertEqual('200');
      expect(backend.betterCursor('200', '100')).assertEqual('200');
      // 非法候选值不推进游标。
      expect(backend.betterCursor('200', '')).assertEqual('200');
      expect(backend.betterCursor('', '0')).assertEqual('');
    });

    it('v2_cursor_roundtrip_and_legacy_replay', 0, () => {
      const encoded: string = encodeCloudCursor(1700000000000, 'tag:中文:😀');
      const parsed: CloudCursor = parseCloudCursor(encoded);
      expect(parsed.versioned).assertTrue();
      expect(parsed.updatedAt).assertEqual(1700000000000);
      expect(parsed.recordKey).assertEqual('tag:中文:😀');
      expect(parseCloudCursor('1700000000000').updatedAt).assertEqual(0);
      expect(parseCloudCursor('v2:100:3:ab').versioned).assertFalse();
      expect(parseCloudCursor('v2:bad:1:a').versioned).assertFalse();
    });

    it('betterCursor_orders_same_timestamp_and_upgrades_legacy', 0, () => {
      const backend: CloudRelayBackend = new CloudRelayBackend(cloudStore);
      const first: string = encodeCloudCursor(100, 'tag:a');
      const second: string = encodeCloudCursor(100, 'tag:b');
      expect(backend.betterCursor(first, second)).assertEqual(second);
      expect(backend.betterCursor(second, first)).assertEqual(second);
      expect(backend.betterCursor('200', first)).assertEqual(first);
      expect(backend.betterCursor(second, '200')).assertEqual(second);
      const bmpKey: string = encodeCloudCursor(100, 'tag:\uE000');
      const emojiKey: string = encodeCloudCursor(100, 'tag:😀');
      expect(backend.betterCursor(bmpKey, emojiKey)).assertEqual(emojiKey);
    });

    it('pull_keeps_201_records_with_identical_timestamp', 0, async () => {
      const rows: SyncRecord[] = [];
      for (let i = 0; i < 201; i += 1) {
        const key: string = 'item:' + ('000' + i).slice(-3);
        rows.push(new SyncRecord(key, 'feed', 1000, false, '{}', 'test'));
      }
      const backend: CloudRelayBackend = new CloudRelayBackend(new MemoryCloudStore(rows));
      const first: SyncPullPage = await backend.pull('', 200);
      expect(first.records.length).assertEqual(200);
      const second: SyncPullPage = await backend.pull(first.cursor, 200);
      expect(second.records.length).assertEqual(1);
      expect(second.records[0].key).assertEqual('item:200');
      expect((await backend.pull(second.cursor, 200)).records.length).assertEqual(0);
      expect((await backend.pull('1000', 200)).records.length).assertEqual(200);
    });

    it('cloud_page_sql_resumes_at_same_timestamp', 0, async () => {
      const injected: common.UIAbilityContext | undefined = TestContext.value;
      const context: common.Context = injected !== undefined
        ? injected : abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const dbName: string = 'cloud_page_test_' + Date.now() + '.db';
      const config: relationalStore.StoreConfig = {
        name: dbName,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      let store: relationalStore.RdbStore | undefined = undefined;
      try {
        store = await relationalStore.getRdbStore(context, config);
        store.executeSync('CREATE TABLE cloudSyncRecords (' +
          'recordKey TEXT PRIMARY KEY, kind TEXT, payload TEXT, updatedAt TEXT, deleted INTEGER, origin TEXT)');
        for (let i = 0; i < 201; i += 1) {
          const key: string = 'item:' + ('000' + i).slice(-3);
          store.executeSync('INSERT INTO cloudSyncRecords VALUES (?,?,?,?,?,?)',
            [key, 'feed', '{}', '1000', 0, 'test']);
        }
        const first: relationalStore.ResultSet = await store.querySql(CLOUD_PAGE_SQL, [0, 0, '', 200]);
        let count: number = 0;
        let lastKey: string = '';
        try {
          while (first.goToNextRow()) {
            count += 1;
            lastKey = first.getString(first.getColumnIndex('recordKey'));
          }
        } finally {
          first.close();
        }
        expect(count).assertEqual(200);
        expect(lastKey).assertEqual('item:199');
        const second: relationalStore.ResultSet = await store.querySql(CLOUD_PAGE_SQL,
          [1000, 1000, lastKey, 200]);
        try {
          expect(second.goToNextRow()).assertTrue();
          expect(second.getString(second.getColumnIndex('recordKey'))).assertEqual('item:200');
          expect(second.goToNextRow()).assertFalse();
        } finally {
          second.close();
        }
      } finally {
        if (store !== undefined) {
          store.close();
        }
        await relationalStore.deleteRdbStore(context, dbName);
      }
    });
  });
}
