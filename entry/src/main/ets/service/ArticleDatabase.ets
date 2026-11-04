/* Shared RDB connection, migration and index initialization. */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ArticleDbConstants, SearchConstants } from '../common/constants/RssConstants';
import { escapeFtsToken } from './SearchQueryParser';
import { DOMAIN, TAG, SQL_CREATE, SQL_CREATE_HIGHLIGHTS, SQL_ADD_IMAGE, SQL_ADD_AUTHOR, SQL_ADD_PROGRESS, SQL_ADD_PROGRESS_RATIO, SQL_ADD_CONTENT_HTML, SQL_ADD_PAGE_ETAG, SQL_ADD_PAGE_LAST_MODIFIED, SQL_ADD_PLAIN_TEXT, SQL_ADD_SAVED, SQL_ADD_READER, SQL_ADD_HIDDEN, SQL_ADD_LINK_KEY, SQL_ADD_TITLE_KEY, SQL_ADD_CANONICAL, SQL_ADD_ENCLOSURES, SQL_ADD_MEDIA_PROGRESS, SQL_CREATE_TRASH, SQL_INDEXES, SQL_CREATE_TAGS, SQL_CREATE_FEEDS, SQL_CREATE_ARTICLE_TAGS, SQL_CREATE_SMART_FOLDERS, SQL_INDEXES_V4, SQL_CREATE_REMOTE_ACCOUNTS, SQL_CREATE_SYNC_STATE, SQL_CREATE_REMOTE_MAP, SQL_CREATE_SYNC_OUTBOX, SQL_CREATE_SYNC_RECORDS, SQL_INDEXES_V9, SQL_INDEXES_V5, SQL_CREATE_RULES, SQL_INDEXES_V6, SQL_INDEXES_V7 } from './ArticleSchema';

export abstract class ArticleDatabase {
  private readonly dbName: string;
  protected store: relationalStore.RdbStore | undefined = undefined;
  /** open() 是否已开始（用于区分「还没打开」与「正在打开」）。 */
  protected openStarted: boolean = false;
  /** open() 是否已结束（成功或降级）。 */
  protected readyResolved: boolean = false;
  protected readyResolve: (() => void) | undefined = undefined;
  /** 库就绪信号：open() 结束后 resolve，供标签 / 智能文件夹等旁路 Store 等待，避免冷启动读到空库。 */
  protected readyPromise: Promise<void> = new Promise<void>((resolve: () => void) => {
    this.readyResolve = resolve;
  });
  /** FTS 是否可用（建表失败 / 迁移降级时为 false，检索走 LIKE）。 */
  protected ftsReady: boolean = false;
  /** 中文二元组索引是否可用（建表失败时为 false，中文检索降级为 LIKE）。 */
  protected cjkReady: boolean = false;
  /** 最新版库的全量索引计数校验延后到首屏之后。 */
  private verifyIndexesLater: boolean = false;
  /** 设备中文分词能力（启动探针结论：文本 MATCH 是否真的可用）。 */
  protected cjkFtsCapable: boolean = false;
  /** 最近一次统计的中文索引条数。 */
  protected cjkIndexedCount: number = 0;
  /** 最近一次检索路径（fts / cjk / like；空串表示还没检索过）。 */
  protected lastSearchPath: string = '';
  /** 最近一次检索耗时（毫秒）。 */
  protected lastSearchMillis: number = 0;

  abstract rebuildSearchIndex(onProgress: (done: number, total: number) => void): Promise<void>;
  abstract rebuildCjkIndex(onProgress: (done: number, total: number) => void): Promise<void>;
  protected abstract ftsCount(): Promise<number>;
  protected abstract cjkCount(): Promise<number>;
  protected abstract countIndexable(): Promise<number>;

  constructor(dbName: string = ArticleDbConstants.DB_NAME) {
    this.dbName = dbName;
  }

  /** 打开（必要时建表 / 迁移）本地库。失败时降级为「无缓存」而不是崩溃。 */
  async open(context: common.Context): Promise<void> {
    const startedAt: number = Date.now();
    this.openStarted = true;
    try {
      const config: relationalStore.StoreConfig = {
        name: this.dbName,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      // 分词器只通过官方入口 StoreConfig.tokenizer 配置（建表语句里不再写 tokenize 子句）；
      // 设备不支持时退回默认分词：中文检索由中文二元组索引兜住，不再依赖分词器能力。
      let icu: boolean = false;
      try {
        icu = relationalStore.isTokenizerSupported(relationalStore.Tokenizer.ICU_TOKENIZER);
        if (icu) {
          config.tokenizer = relationalStore.Tokenizer.ICU_TOKENIZER;
        }
      } catch (err) {
        hilog.info(DOMAIN, TAG, 'tokenizer probe failed');
      }
      try {
        this.store = await relationalStore.getRdbStore(context, config);
      } catch (err) {
        if (!icu) {
          throw err as Error;
        }
        // 分词器配置与既有库不兼容：退回默认配置再开一次（检索降级，但数据可读）。
        const fallback: relationalStore.StoreConfig = {
          name: this.dbName,
          securityLevel: relationalStore.SecurityLevel.S1
        };
        this.store = await relationalStore.getRdbStore(context, fallback);
        hilog.warn(DOMAIN, TAG, 'open with icu tokenizer failed, fell back to default');
      }
      hilog.info(DOMAIN, TAG, 'startup dbConnection=%{public}dms', Date.now() - startedAt);
      this.store.executeSync(SQL_CREATE);
      // 一次读取现有列，仅对缺列执行 ALTER；保留升级被打断后的逐列自愈能力。
      this.ensureArticleColumns();
      hilog.info(DOMAIN, TAG, 'startup dbColumns=%{public}dms', Date.now() - startedAt);
      this.store.executeSync(SQL_CREATE_HIGHLIGHTS);
      // 标签 / 智能文件夹：即使库已是最新版本也执行一遍（自愈：上次建表失败 / 被打断）。
      this.createTagTables();
      // v10 订阅源表：每次打开都补一次（升级被打断 / 建表失败都能自愈）。
      this.createFeedTables();
      // 远端账号 / 游标 / 映射 / 待同步队列同理：最新版本也自愈。
      this.createRemoteTables();
      // 规则表同理：最新版本也自愈（建表失败只让规则功能降级为空态）。
      this.createRuleTables();
      // v7 去重索引同理：最新版本也自愈（缺索引只是慢，功能不受影响）。
      this.createDedupeIndexes();
      hilog.info(DOMAIN, TAG, 'startup dbTables=%{public}dms', Date.now() - startedAt);
      // 结构迁移失败不删库：仅降级（无检索 / 无回收站），下次启动会重试。
      try {
        await this.migrate();
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.error(DOMAIN, TAG, 'migrate failed, degraded: %{public}d', error.code);
      }
      hilog.info(DOMAIN, TAG, 'startup dbMigrate=%{public}dms', Date.now() - startedAt);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'open failed: %{public}d', error.code);
      this.store = undefined;
      this.ftsReady = false;
      this.cjkReady = false;
    }
    this.markReady();
    // 分词能力与 DDL 日志仅供诊断，不参与列表加载和搜索路径选择。
    // 首屏后再探测，避免启动时为临时 FTS 表建删和日志查询等待数据库。
    if (this.store !== undefined) {
      setTimeout(() => {
        this.verifySearchIndexes().then(() => this.probeCjkFts()).then((capable: boolean) => {
          this.cjkFtsCapable = capable;
          hilog.info(DOMAIN, TAG, 'CJKIDX probe result=%{public}s', capable ? 'capable' : 'unavailable');
          this.logIndexSchema().catch(() => {});
        }).catch(() => {});
      }, 500);
    }
    hilog.info(DOMAIN, TAG, 'startup databaseOpen=%{public}dms', Date.now() - startedAt);
  }

  /**
   * 等待库打开结束（成功或降级）。
   * open() 尚未开始时立即返回，避免旁路 Store 在测试 / 无库场景下永久挂起。
   */
  whenReady(): Promise<void> {
    if (this.readyResolved || !this.openStarted) {
      return Promise.resolve();
    }
    return this.readyPromise;
  }

  protected markReady(): void {
    if (this.readyResolved) {
      return;
    }
    this.readyResolved = true;
    const resolve: (() => void) | undefined = this.readyResolve;
    if (resolve !== undefined) {
      resolve();
    }
  }

  /** 版本化迁移：v1 = 初始表；v2 = 索引 + 回收站 + FTS；v3 = 中文检索索引；v4 = 标签 + 智能文件夹；
   *  v5 = 远端同步表；v6 = 规则表 + articles.is_hidden；
   *  v7 = 跨源去重：articles.link_key / title_key / canonical_id + 3 个索引；
   *  v8 = 媒体附件 articles.enclosures + 音频进度 articles.media_progress。 */
  protected async migrate(): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    let version: number = 0;
    try {
      version = store.version;
    } catch (err) {
      version = 0;
    }
    if (version >= ArticleDbConstants.SCHEMA_VERSION) {
      // 表的自愈仍在启动时完成；索引是否可查询立即确认，保证新文章写入索引。
      // 全量条数校验可能扫描大量文章，留到首屏之后执行。
      this.ftsReady = await this.detectFts();
      if (!this.ftsReady) {
        await this.createFts();
      }
      this.cjkReady = await this.detectCjk();
      if (!this.cjkReady) {
        this.createCjk();
      }
      this.verifyIndexesLater = true;
      return;
    }
    // 结构升级（v1 → v2 → v3 → v4，语句都可重复执行）。
    for (let i = 0; i < SQL_INDEXES.length; i += 1) {
      try {
        store.executeSync(SQL_INDEXES[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'create index failed: %{public}d', error.code);
      }
    }
    store.executeSync(SQL_CREATE_TRASH);
    this.createTagTables();
    this.createRemoteTables();
    this.createRuleTables();
    this.createFeedTables();
    this.createDedupeIndexes();
    const mainStale: boolean = await this.ensureMainIndex();
    const cjkStale: boolean = await this.ensureCjkIndex();
    try {
      store.version = ArticleDbConstants.SCHEMA_VERSION;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'set version failed: %{public}d', error.code);
    }
    // 首次升级：把已有文章灌进索引（后台分批，避免拖慢冷启动）。
    if (mainStale) {
      this.backgroundRebuildMain();
    }
    if (cjkStale) {
      this.backgroundRebuildCjk();
    }
  }

  /** 对最新版库补做条数校验；遗漏或中断的索引仍按原逻辑后台重建。 */
  private async verifySearchIndexes(): Promise<void> {
    if (!this.verifyIndexesLater) {
      return;
    }
    this.verifyIndexesLater = false;
    const mainStale: boolean = await this.ensureMainIndex();
    const cjkStale: boolean = await this.ensureCjkIndex();
    if (mainStale) {
      this.backgroundRebuildMain();
    }
    if (cjkStale) {
      this.backgroundRebuildCjk();
    }
  }

  /**
   * 建 v4 的三张表与索引（可重复执行）。
   *
   * 每条单独 try/catch：任何一条失败都只记日志、不影响其它语句，也不影响阅读 / 检索主链路 ——
   * 标签功能降级为「页面空态」，下次启动再自愈。
   */
  /** 建 v10 订阅源表（可重复执行；失败只降级为「订阅仍走偏好库」）。 */
  protected createFeedTables(): void {
    try {
      this.store?.executeSync(SQL_CREATE_FEEDS);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'create feed table failed: %{public}d', error.code);
    }
  }

  protected createTagTables(): void {
    const statements: string[] = [SQL_CREATE_TAGS, SQL_CREATE_ARTICLE_TAGS, SQL_CREATE_SMART_FOLDERS];
    for (let i = 0; i < statements.length; i += 1) {
      try {
        this.store?.executeSync(statements[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.error(DOMAIN, TAG, 'create tag table failed: %{public}d', error.code);
      }
    }
    for (let i = 0; i < SQL_INDEXES_V4.length; i += 1) {
      try {
        this.store?.executeSync(SQL_INDEXES_V4[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'create tag index failed: %{public}d', error.code);
      }
    }
  }

  /**
   * 暴露共享连接：标签 / 智能文件夹 Store 复用它，避免同进程重复打开同名数据库。
   * undefined 表示库不可用（打开失败 / 正在降级），调用方应返回空态而不是抛错。
   */
  getStore(): relationalStore.RdbStore | undefined {
    return this.store;
  }

  /**
   * 建 v5 的四张表与索引（可重复执行）。
   * 每条单独 try/catch：任何一条失败只记日志，不影响阅读 / 检索主链路 ——
   * 远端同步功能降级，下次启动再自愈。
   */
  protected createRemoteTables(): void {
    const statements: string[] = [
      SQL_CREATE_REMOTE_ACCOUNTS, SQL_CREATE_SYNC_STATE,
      SQL_CREATE_REMOTE_MAP, SQL_CREATE_SYNC_OUTBOX, SQL_CREATE_SYNC_RECORDS
    ];
    for (let i = 0; i < statements.length; i += 1) {
      try {
        this.store?.executeSync(statements[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.error(DOMAIN, TAG, 'create remote table failed: %{public}d', error.code);
      }
    }
    for (let i = 0; i < SQL_INDEXES_V5.length; i += 1) {
      try {
        this.store?.executeSync(SQL_INDEXES_V5[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'create remote index failed: %{public}d', error.code);
      }
    }
    for (let i = 0; i < SQL_INDEXES_V9.length; i += 1) {
      try {
        this.store?.executeSync(SQL_INDEXES_V9[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'create sync record index failed: %{public}d', error.code);
      }
    }
  }

  /**
   * 建 v6 的规则表与索引（可重复执行）。
   * 每条单独 try/catch：失败只让规则功能降级为空态，不影响文章入库 / 阅读 / 检索。
   */
  protected createRuleTables(): void {
    try {
      this.store?.executeSync(SQL_CREATE_RULES);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'create rules table failed: %{public}d', error.code);
    }
    for (let i = 0; i < SQL_INDEXES_V6.length; i += 1) {
      try {
        this.store?.executeSync(SQL_INDEXES_V6[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'create rules index failed: %{public}d', error.code);
      }
    }
  }

  /**
   * 建 v7 的去重索引（可重复执行）。
   * 每条单独 try/catch：失败只让入库去重退化为全表扫描（变慢但结果一致），不影响入库本身。
   */
  protected createDedupeIndexes(): void {
    for (let i = 0; i < SQL_INDEXES_V7.length; i += 1) {
      try {
        this.store?.executeSync(SQL_INDEXES_V7[i]);
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'create dedupe index failed: %{public}d', error.code);
      }
    }
  }

  /** 后台重建主索引（升级 / 补建后回填，不阻塞启动）。 */
  protected backgroundRebuildMain(): void {
    this.rebuildSearchIndex((): void => {
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'fts backfill failed: %{public}d', err.code);
    });
  }

  /** 后台重建中文索引（升级 / 补建 / 条数不一致时回填，不阻塞启动）。 */
  protected backgroundRebuildCjk(): void {
    this.rebuildCjkIndex((): void => {
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'cjk backfill failed: %{public}d', err.code);
    });
  }

  /**
   * 确保主索引可用。返回 true 表示需要重建：索引条数与「需要索引的文章数」不一致
   * （跨源重复项不建索引，所以比的是主条数；建表晚于入库导致部分行缺失 / 重建被打断也会命中）。
   * 空库（文章 0 且索引 0）不需要重建。
   */
  protected async ensureMainIndex(): Promise<boolean> {
    this.ftsReady = await this.detectFts();
    if (!this.ftsReady) {
      await this.createFts();
    }
    if (!this.ftsReady) {
      return false;
    }
    const indexed: number = await this.ftsCount();
    const total: number = await this.countIndexable();
    if (indexed === 0 && total === 0) {
      return false;
    }
    if (indexed !== total) {
      hilog.info(DOMAIN, TAG, 'main index mismatch indexed=%{public}d total=%{public}d',
        indexed, total);
      return true;
    }
    return false;
  }

  /**
   * 确保中文索引可用。返回 true 表示需要重建（表刚建好，或条数与主条数不一致 —— 重建被打断 / 有未同步的新数据）。
   * 建表失败时置 cjkReady = false 并返回 false：中文检索降级为 LIKE，功能仍可用。
   */
  protected async ensureCjkIndex(): Promise<boolean> {
    this.cjkReady = await this.detectCjk();
    if (!this.cjkReady) {
      this.createCjk();
    }
    if (!this.cjkReady) {
      this.cjkIndexedCount = 0;
      hilog.warn(DOMAIN, TAG, 'CJKIDX cjk index degraded (create failed)');
      return false;
    }
    this.cjkIndexedCount = await this.cjkCount();
    const total: number = await this.countIndexable();
    if (this.cjkIndexedCount === 0 && total === 0) {
      return false;
    }
    if (this.cjkIndexedCount !== total) {
      hilog.info(DOMAIN, TAG, 'CJKIDX cjk index mismatch indexed=%{public}d total=%{public}d',
        this.cjkIndexedCount, total);
      return true;
    }
    return false;
  }

  /** 主索引建表：分词器只由 StoreConfig.tokenizer 提供（不再写 tokenize 子句）；失败则检索降级。 */
  protected async createFts(): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    const columns: string = 'article_id UNINDEXED, title, summary, plain_text, author';
    try {
      store.executeSync('CREATE VIRTUAL TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_ARTICLES_FTS +
        ' USING fts5(' + columns + ')');
      this.ftsReady = true;
      hilog.info(DOMAIN, TAG, 'fts ready');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'create fts failed, degrade to like: %{public}d %{public}s',
        error.code, error.message);
      this.ftsReady = false;
    }
  }

  /**
   * 中文索引建表：显式 unicode61，保证写入的「字 / 二元组」token 原样保留、不被再次切碎。
   * 不使用其它分词参数；失败即降级（不重试别的写法）。
   */
  protected createCjk(): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync('CREATE VIRTUAL TABLE IF NOT EXISTS ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK +
        ' USING fts5(article_id UNINDEXED, grams, tokenize=\'unicode61\')');
      this.cjkReady = true;
      hilog.info(DOMAIN, TAG, 'CJKIDX cjk index ready');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'CJKIDX create cjk fts failed: %{public}d %{public}s',
        error.code, error.message);
      this.cjkReady = false;
    }
  }

  /**
   * 中文分词能力探针：临时 FTS 表 + 中文样本 + 真实 MATCH。
   * 只有查询命中才算「中文分词可用」；失败静默（结论为不可用），探测表一定被清理。
   */
  protected async probeCjkFts(): Promise<boolean> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return false;
    }
    const table: string = SearchConstants.PROBE_TABLE;
    try {
      store.executeSync('DROP TABLE IF EXISTS ' + table);
      store.executeSync('CREATE VIRTUAL TABLE ' + table + ' USING fts5(body)');
      store.executeSync('INSERT INTO ' + table + ' (body) VALUES (?)', [SearchConstants.PROBE_SAMPLE]);
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM ' + table + ' WHERE body MATCH ?',
        [escapeFtsToken(SearchConstants.PROBE_TERM)]);
      try {
        const hit: number = rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
        return hit > 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'CJKIDX probe failed: %{public}d %{public}s', error.code, error.message);
      return false;
    } finally {
      this.dropProbeTable();
    }
  }

  /** 清理探针临时表（失败忽略：表可能根本没建成）。 */
  protected dropProbeTable(): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync('DROP TABLE IF EXISTS ' + SearchConstants.PROBE_TABLE);
    } catch (err) {
      hilog.info(DOMAIN, TAG, 'CJKIDX probe table cleanup skipped');
    }
  }

  /** 探测 FTS 是否可用（表存在且能查询）。 */
  protected async detectFts(): Promise<boolean> {
    return await this.tableQueryable(ArticleDbConstants.TABLE_ARTICLES_FTS);
  }

  /**
   * 启动时把两张索引虚表的真实 DDL 打进日志（诊断用）：
   * 建表失败 / 旧版本残留 / 分词参数不符时，只有 sqlite_master 里的原文能说明问题。
   */
  protected async logIndexSchema(): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    const tables: string[] = [ArticleDbConstants.TABLE_ARTICLES_FTS, ArticleDbConstants.TABLE_ARTICLES_FTS_CJK];
    for (let i = 0; i < tables.length; i += 1) {
      try {
        const rs: relationalStore.ResultSet = await store.querySql(
          'SELECT sql FROM sqlite_master WHERE type = ? AND name = ?', ['table', tables[i]]);
        try {
          const ddl: string = rs.goToNextRow() ? rs.getString(rs.getColumnIndex('sql')) : '';
          hilog.info(DOMAIN, TAG, 'CJKIDX schema %{public}s: %{public}s',
            tables[i], ddl.length > 0 ? ddl : '(missing)');
        } finally {
          rs.close();
        }
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'CJKIDX schema dump failed: %{public}d %{public}s',
          error.code, error.message);
      }
    }
  }

  /** 探测中文索引表是否可用。 */
  protected async detectCjk(): Promise<boolean> {
    return await this.tableQueryable(ArticleDbConstants.TABLE_ARTICLES_FTS_CJK);
  }

  protected async tableQueryable(table: string): Promise<boolean> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return false;
    }
    // 先以 sqlite_master 为准确认表真的存在：仅靠 SELECT 是否抛错判断会误判（缺表时可能返回空结果集）。
    if (!(await this.tableExists(table))) {
      return false;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql('SELECT COUNT(*) AS c FROM ' + table);
      try {
        return rs.goToNextRow();
      } finally {
        rs.close();
      }
    } catch (err) {
      return false;
    }
  }

  /** 表是否存在于当前库（sqlite_master 为准）。 */
  protected async tableExists(table: string): Promise<boolean> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return false;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM sqlite_master WHERE type = ? AND name = ?', ['table', table]);
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) > 0 : false;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'table exists check failed: %{public}d %{public}s',
        error.code, error.message);
      return false;
    }
  }

  /** 上一条语句影响的行数（同连接内 changes()）。 */
  protected lastChanges(): number {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = store.querySqlSync('SELECT changes() AS c');
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      return 0;
    }
  }

  /** 一次检查所有列，避免正常启动时为每个已存在的列抛异常。 */
  protected ensureArticleColumns(): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    const migrations: string[] = [
      SQL_ADD_IMAGE, SQL_ADD_AUTHOR, SQL_ADD_PROGRESS, SQL_ADD_PROGRESS_RATIO,
      SQL_ADD_READER, SQL_ADD_CONTENT_HTML, SQL_ADD_PLAIN_TEXT, SQL_ADD_PAGE_ETAG,
      SQL_ADD_PAGE_LAST_MODIFIED, SQL_ADD_SAVED, SQL_ADD_HIDDEN, SQL_ADD_LINK_KEY,
      SQL_ADD_TITLE_KEY, SQL_ADD_CANONICAL, SQL_ADD_ENCLOSURES, SQL_ADD_MEDIA_PROGRESS
    ];
    const columns: Set<string> = new Set<string>();
    let inspected: boolean = false;
    try {
      const rs: relationalStore.ResultSet = store.querySqlSync(
        'PRAGMA table_info(' + ArticleDbConstants.TABLE_ARTICLES + ')');
      try {
        while (rs.goToNextRow()) {
          columns.add(rs.getString(rs.getColumnIndex('name')));
        }
        inspected = columns.size > 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'column inspection failed, falling back to ALTER checks');
    }
    for (let i = 0; i < migrations.length; i += 1) {
      const sql: string = migrations[i];
      const column: string = sql.split(' ADD COLUMN ')[1].split(' ')[0];
      if (!inspected || !columns.has(column)) {
        this.addColumnIfNeeded(sql);
      }
    }
  }

  /** 只为老库补列：列已存在时 executeSync 会抛错，这里静默处理。 */
  protected addColumnIfNeeded(sql: string): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync(sql);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.info(DOMAIN, TAG, 'column already present: %{public}d', error.code);
    }
  }

  protected exec(sql: string, args: Array<relationalStore.ValueType>): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.executeSync(sql, args);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'exec failed: %{public}d %{public}s', error.code, error.message);
    }
  }
}
