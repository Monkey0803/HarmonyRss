/*
 * SearchPerf.test.ets — 1 万篇中文检索压测（设备上运行，验证 SC-001/SC-002）。
 *
 * 使用独立的临时数据库（bench_<ts>.db），按线上同构的表结构与 SQL 构造 1 万篇文章：
 *   articles + articles_fts + articles_fts_cjk(unicode61)
 * 查询语句与 ArticleStore.searchCjk / searchFts 保持一致（计数 + 取页），
 * 结束后删除临时库，不触碰应用真实数据。
 *
 * 注意：测试 HAP 会覆盖主包，跑完需重装主包。
 */

import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { TestContext } from './TestContext';
import { relationalStore } from '@kit.ArkData';
import { grams, queryTokens } from '../../../main/ets/service/CjkTokenizer';
import { escapeFtsToken } from '../../../main/ets/service/SearchQueryParser';

const TOTAL: number = 10000;
const BATCH: number = 500;
const ROUNDS: number = 5;
const PAGE_SIZE: number = 30;
const DOUBLE_LIMIT_MS: number = 800;
const SINGLE_LIMIT_MS: number = 1000;

const SQL_ARTICLES: string =
  'CREATE TABLE IF NOT EXISTS articles (' +
  'id TEXT PRIMARY KEY, feed_title TEXT NOT NULL DEFAULT \'\', title TEXT NOT NULL DEFAULT \'\',' +
  'summary TEXT NOT NULL DEFAULT \'\', plain_text TEXT NOT NULL DEFAULT \'\',' +
  'published_at INTEGER NOT NULL DEFAULT 0, is_read INTEGER NOT NULL DEFAULT 0,' +
  'is_starred INTEGER NOT NULL DEFAULT 0, is_saved INTEGER NOT NULL DEFAULT 0,' +
  'author TEXT NOT NULL DEFAULT \'\')';

const SQL_FTS: string =
  'CREATE VIRTUAL TABLE IF NOT EXISTS articles_fts USING fts5(' +
  'article_id UNINDEXED, title, summary, plain_text, author)';

const SQL_FTS_CJK: string =
  'CREATE VIRTUAL TABLE IF NOT EXISTS articles_fts_cjk USING fts5(' +
  'article_id UNINDEXED, grams, tokenize=\'unicode61\')';

class Timing {
  readonly label: string;
  readonly total: number;
  readonly minMs: number;
  readonly avgMs: number;
  readonly maxMs: number;

  constructor(label: string, total: number, minMs: number, avgMs: number, maxMs: number) {
    this.label = label;
    this.total = total;
    this.minMs = minMs;
    this.avgMs = avgMs;
    this.maxMs = maxMs;
  }
}

function bodyOf(index: number): string {
  const sentence: string =
    '鸿蒙系统开发与中文全文检索性能测试，荣耀发布新品，发布之后继续开发并验证检索链路。';
  return sentence + sentence + sentence + sentence + '第' + index + '篇。';
}

function titleOf(index: number): string {
  return '压测 ' + index + ' 荣耀发布 鸿蒙系统 WASM Rust harmony';
}

async function countOf(store: relationalStore.RdbStore, sql: string,
  args: Array<relationalStore.ValueType>): Promise<number> {
  const rs: relationalStore.ResultSet = await store.querySql(sql, args);
  try {
    return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
  } finally {
    rs.close();
  }
}

/** 中文索引路径：与 ArticleStore.searchCjk 同构（COUNT(DISTINCT) + SELECT DISTINCT）。 */
async function measureCjk(store: relationalStore.RdbStore, raw: string): Promise<Timing> {
  const tokens: string[] = queryTokens(raw);
  const expression: string = tokens.map((token: string) => escapeFtsToken(token)).join(' AND ');
  const needPost: boolean = raw.length >= 3;
  const post: string = needPost
    ? ' AND (instr(lower(a.title), ?) > 0 OR instr(lower(a.summary), ?) > 0' +
      ' OR instr(lower(a.plain_text), ?) > 0)'
    : '';
  const countSql: string = 'SELECT COUNT(DISTINCT a.id) AS c FROM articles_fts_cjk' +
    ' JOIN articles a ON a.id = articles_fts_cjk.article_id WHERE articles_fts_cjk MATCH ?' + post;
  const pageSql: string = 'SELECT DISTINCT a.id, a.title FROM articles_fts_cjk' +
    ' JOIN articles a ON a.id = articles_fts_cjk.article_id WHERE articles_fts_cjk MATCH ?' + post +
    ' ORDER BY a.published_at DESC LIMIT ? OFFSET ?';

  let total: number = 0;
  let minMs: number = Number.MAX_VALUE;
  let maxMs: number = 0;
  let sum: number = 0;
  for (let i = 0; i < ROUNDS; i += 1) {
    const countArgs: Array<relationalStore.ValueType> = [expression];
    if (needPost) {
      countArgs.push(raw);
      countArgs.push(raw);
      countArgs.push(raw);
    }
    const pageArgs: Array<relationalStore.ValueType> = [expression];
    if (needPost) {
      pageArgs.push(raw);
      pageArgs.push(raw);
      pageArgs.push(raw);
    }
    pageArgs.push(PAGE_SIZE);
    pageArgs.push(0);

    const started: number = Date.now();
    total = await countOf(store, countSql, countArgs);
    const rs: relationalStore.ResultSet = await store.querySql(pageSql, pageArgs);
    rs.close();
    const cost: number = Math.max(0, Date.now() - started);
    if (i > 0) {
      // 第一轮作为预热，不计入统计。
      sum += cost;
      minMs = Math.min(minMs, cost);
      maxMs = Math.max(maxMs, cost);
    }
  }
  return new Timing(raw, total, minMs, Math.round(sum / (ROUNDS - 1)), maxMs);
}

/** 英文主索引路径：与 ArticleStore.searchFts 同构。 */
async function measureFts(store: relationalStore.RdbStore, raw: string): Promise<Timing> {
  const expression: string = escapeFtsToken(raw);
  const countSql: string = 'SELECT COUNT(*) AS c FROM articles_fts' +
    ' JOIN articles a ON a.id = articles_fts.article_id WHERE articles_fts MATCH ?';
  const pageSql: string = 'SELECT a.id, a.title FROM articles_fts' +
    ' JOIN articles a ON a.id = articles_fts.article_id WHERE articles_fts MATCH ?' +
    ' ORDER BY a.published_at DESC LIMIT ? OFFSET ?';
  let total: number = 0;
  let minMs: number = Number.MAX_VALUE;
  let maxMs: number = 0;
  let sum: number = 0;
  for (let i = 0; i < ROUNDS; i += 1) {
    const started: number = Date.now();
    total = await countOf(store, countSql, [expression]);
    const rs: relationalStore.ResultSet = await store.querySql(pageSql, [expression, PAGE_SIZE, 0]);
    rs.close();
    const cost: number = Math.max(0, Date.now() - started);
    if (i > 0) {
      sum += cost;
      minMs = Math.min(minMs, cost);
      maxMs = Math.max(maxMs, cost);
    }
  }
  return new Timing(raw, total, minMs, Math.round(sum / (ROUNDS - 1)), maxMs);
}

export default function searchPerfTest() {
  describe('SearchPerf', () => {
    it('search_10k_cjk', 0, async () => {
      const injected: common.UIAbilityContext | undefined = TestContext.value;
      const context: common.Context = injected !== undefined
        ? injected
        : abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const dbName: string = 'bench_' + Date.now() + '.db';
      const config: relationalStore.StoreConfig = {
        name: dbName,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      let opened: relationalStore.RdbStore | undefined = undefined;
      try {
        const db: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
        opened = db;
        db.executeSync(SQL_ARTICLES);
        db.executeSync(SQL_FTS);
        db.executeSync(SQL_FTS_CJK);

        // ---- 灌入 1 万篇 ----
        const now: number = Date.now();
        const insertArticle: string =
          'INSERT OR REPLACE INTO articles (id, feed_title, title, summary, plain_text,' +
          ' published_at, is_read, is_starred, is_saved, author) VALUES (?,?,?,?,?,?,?,?,?,?)';
        const insertFts: string =
          'INSERT INTO articles_fts (article_id, title, summary, plain_text, author) VALUES (?,?,?,?,?)';
        const insertCjk: string =
          'INSERT INTO articles_fts_cjk (article_id, grams) VALUES (?,?)';
        for (let start = 0; start < TOTAL; start += BATCH) {
          const end: number = Math.min(start + BATCH, TOTAL);
          db.beginTransaction();
          try {
            for (let i = start; i < end; i += 1) {
              const id: string = 'bench_' + i;
              const title: string = titleOf(i);
              const summary: string = '鸿蒙系统开发与中文全文检索性能测试，荣耀发布。';
              const plain: string = bodyOf(i);
              db.executeSync(insertArticle,
                [id, '压测源', title, summary, plain, now - i * 60000, 0, 0, 0, 'tester']);
              db.executeSync(insertFts, [id, title, summary, plain, 'tester']);
              db.executeSync(insertCjk, [id, grams(title + ' ' + summary + ' ' + plain, 20000)]);
            }
            db.commit();
          } catch (inner) {
            db.rollBack();
            throw inner as Error;
          }
        }
        const count: number = await countOf(db, 'SELECT COUNT(*) AS c FROM articles', []);
        console.info('PERF inserted total=' + count);

        // ---- 计时 ----
        const single: Timing = await measureCjk(db, '发');
        const doubleTiming: Timing = await measureCjk(db, '发布');
        const four: Timing = await measureCjk(db, '荣耀发布');
        const mixed: Timing = await measureCjk(db, '鸿蒙系统');
        const english: Timing = await measureFts(db, 'harmony');

        console.info('PERF single  ' + single.label + ' total=' + single.total +
          ' min=' + single.minMs + ' avg=' + single.avgMs + ' max=' + single.maxMs);
        console.info('PERF double  ' + doubleTiming.label + ' total=' + doubleTiming.total +
          ' min=' + doubleTiming.minMs + ' avg=' + doubleTiming.avgMs + ' max=' + doubleTiming.maxMs);
        console.info('PERF four    ' + four.label + ' total=' + four.total +
          ' min=' + four.minMs + ' avg=' + four.avgMs + ' max=' + four.maxMs);
        console.info('PERF mixed   ' + mixed.label + ' total=' + mixed.total +
          ' min=' + mixed.minMs + ' avg=' + mixed.avgMs + ' max=' + mixed.maxMs);
        console.info('PERF english ' + english.label + ' total=' + english.total +
          ' min=' + english.minMs + ' avg=' + english.avgMs + ' max=' + english.maxMs);

        // ---- 正确性 + 性能门槛 ----
        expect(doubleTiming.total > 0).assertTrue();
        expect(four.total > 0).assertTrue();
        expect(single.total > 0).assertTrue();
        expect(english.total > 0).assertTrue();
        expect(doubleTiming.avgMs < DOUBLE_LIMIT_MS).assertTrue();
        expect(single.avgMs < SINGLE_LIMIT_MS).assertTrue();
      } finally {
        if (opened !== undefined) {
          try {
            opened.close();
          } catch (err) {
          }
        }
        try {
          await relationalStore.deleteRdbStore(context, dbName);
          console.info('PERF bench db removed: ' + dbName);
        } catch (err) {
          console.warn('PERF remove bench db failed');
        }
      }
    });
  });
}
