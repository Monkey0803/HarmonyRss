/* Article search, FTS maintenance and diagnostics. */
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ArticleDbConstants, SearchConstants } from '../common/constants/RssConstants';
import { SearchDiagnostics, SearchPage, SearchQuery, SearchHit, SearchState, CjkQueryPlan } from '../model/Search';
import { escapeFtsToken } from './SearchQueryParser';
import { compile, hasCjk, isBlankQuery, postFilterSql } from './SearchPlan';
import { grams } from './CjkTokenizer';
import { toPlainText } from '../common/utils/HtmlText';
import { ArticleDatabase } from './ArticleDatabase';
import { DOMAIN, TAG } from './ArticleSchema';

export class ArticleSearchStore extends ArticleDatabase {
  /** 检索索引是否可用。 */
  isFtsReady(): boolean {
    return this.ftsReady;
  }

  /** 中文索引是否可用（false = 中文检索降级为 LIKE）。 */
  isCjkIndexReady(): boolean {
    return this.cjkReady;
  }

  /** 诊断快照：索引就绪状态 / 条数 / 最近一次检索路径与耗时。 */
  async diagnostics(): Promise<SearchDiagnostics> {
    const mainIndexed: number = await this.ftsCount();
    this.cjkIndexedCount = await this.cjkCount();
    hilog.info(DOMAIN, TAG, 'CJKIDX diagnostics ready=%{public}d/%{public}d main=%{public}d cjk=%{public}d',
      this.ftsReady ? 1 : 0, this.cjkReady ? 1 : 0, mainIndexed, this.cjkIndexedCount);
    return new SearchDiagnostics(this.ftsReady, this.cjkReady, this.cjkFtsCapable,
      mainIndexed, this.cjkIndexedCount, this.lastSearchPath, this.lastSearchMillis);
  }

  /** FTS 行数（诊断 / 判断是否需要首次回填）。 */
  protected async ftsCount(): Promise<number> {
    return await this.tableCount(ArticleDbConstants.TABLE_ARTICLES_FTS, this.ftsReady);
  }

  /** 中文索引行数。 */
  protected async cjkCount(): Promise<number> {
    return await this.tableCount(ArticleDbConstants.TABLE_ARTICLES_FTS_CJK, this.cjkReady);
  }

  /**
   * FTS5 虚表行数。
   * 本 RDB 封装下对 FTS5 虚表直接 COUNT(*) 会返回 0（而 MATCH 查询正常），
   * 故优先统计 FTS5 的文档影子表 `<table>_docsize`（每个文档一行）；
   * 影子表不可用（未建成 / 旧版本）时退回虚表 COUNT(*)；两者都失败静默返回 0。
   */
  protected async tableCount(table: string, ready: boolean): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || !ready) {
      return 0;
    }
    const shadow: string = table + '_docsize';
    try {
      const rs: relationalStore.ResultSet =
        await store.querySql('SELECT COUNT(*) AS c FROM ' + shadow);
      try {
        if (rs.goToNextRow()) {
          return rs.getLong(rs.getColumnIndex('c'));
        }
        hilog.warn(DOMAIN, TAG, 'count %{public}s returned no row, fallback to fts count', shadow);
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'count %{public}s failed, fallback to fts count: %{public}d %{public}s',
        shadow, error.code, error.message);
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql('SELECT COUNT(*) AS c FROM ' + table);
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'count %{public}s failed, report 0: %{public}d %{public}s',
        table, error.code, error.message);
      return 0;
    }
  }

  /**
   * 需要进入检索索引的条数（= 主条数）：
   * 跨源重复项入库时不写索引，若仍拿全表条数比较，每次启动都会误判「索引缺行」并全量重建。
   */
  protected async countIndexable(): Promise<number> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE canonical_id = \'\'');
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'countIndexable failed: %{public}d', error.code);
      return 0;
    }
  }

  /**
   * 全文检索路由（所有过滤条件与分页都在 SQL 层完成）：
   *   含 CJK      → 中文二元组索引（articles_fts_cjk）+ 候选复核；
   *   纯英文      → 主 FTS 索引（articles_fts）；
   *   索引不可用 / 查询异常 → 全表 LIKE 降级（功能仍可用）。
   * 每次检索都记录路径与耗时（诊断 + CJKIDX 日志）。
   */
  async search(query: SearchQuery, offset: number, limit: number): Promise<SearchPage> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || limit <= 0) {
      return SearchPage.empty();
    }
    // 空查询保护：没有任何关键词与过滤条件时直接返回空页，不触发任何扫描。
    if (isBlankQuery(query)) {
      return SearchPage.empty();
    }
    const started: number = Date.now();
    if (hasCjk(query)) {
      if (this.cjkReady) {
        try {
          const plan: CjkQueryPlan = compile(query);
          if (plan.used) {
            const page: SearchPage = await this.searchCjk(store, query, plan, offset, limit);
            return this.finishSearch(page, SearchConstants.PATH_CJK, started);
          }
        } catch (err) {
          const error: BusinessError = err as BusinessError;
          hilog.warn(DOMAIN, TAG, 'CJKIDX cjk search failed, fallback like: %{public}d', error.code);
        }
      } else {
        hilog.info(DOMAIN, TAG, 'CJKIDX cjk index unavailable, like fallback');
      }
      const fallback: SearchPage = await this.searchLike(store, query, offset, limit);
      return this.finishSearch(fallback, SearchConstants.PATH_LIKE, started);
    }
    if (this.ftsReady) {
      try {
        const expression: string = this.ftsExpression(query);
        if (expression.length > 0) {
          const page: SearchPage = await this.searchFts(store, query, expression, offset, limit);
          return this.finishSearch(page, SearchConstants.PATH_FTS, started);
        }
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'fts search failed, falling back to like: %{public}d', error.code);
      }
    }
    const like: SearchPage = await this.searchLike(store, query, offset, limit);
    return this.finishSearch(like, SearchConstants.PATH_LIKE, started);
  }

  /** 记录最近一次检索路径与耗时（诊断状态 + 日志）。 */
  protected finishSearch(page: SearchPage, path: string, started: number): SearchPage {
    const millis: number = Math.max(0, Date.now() - started);
    this.lastSearchPath = path;
    this.lastSearchMillis = millis;
    hilog.info(DOMAIN, TAG, 'CJKIDX search path=%{public}s ms=%{public}d total=%{public}d',
      path, millis, page.total);
    return page;
  }

  /** 拼 FTS5 查询串：短语整体匹配，普通词按 AND；每个词都做转义。 */
  protected ftsExpression(query: SearchQuery): string {
    if (query.phrase.length > 0) {
      return escapeFtsToken(query.phrase);
    }
    const parts: string[] = [];
    for (let i = 0; i < query.terms.length; i += 1) {
      const token: string = escapeFtsToken(query.terms[i]);
      if (token.length > 0) {
        parts.push(token);
      }
    }
    return parts.join(' AND ');
  }

  /**
   * 状态 / 来源 / 时间过滤的 SQL 片段（不含关键词）。
   * 开头的 canonical_id 条件让检索（计数与取页）只命中主条：重复项不进搜索结果。
   */
  protected filterClause(query: SearchQuery, args: Array<relationalStore.ValueType>): string {
    let clause: string = ' AND a.canonical_id = \'\'';
    if (query.state === SearchState.UNREAD) {
      clause += ' AND a.is_read = 0';
    } else if (query.state === SearchState.READ) {
      clause += ' AND a.is_read = 1';
    } else if (query.state === SearchState.STARRED) {
      clause += ' AND a.is_starred = 1';
    } else if (query.state === SearchState.SAVED) {
      clause += ' AND a.is_saved = 1';
    }
    const from: string = query.from.trim();
    if (from.length > 0) {
      clause += ' AND (a.feed_title LIKE ? OR a.feed_id LIKE ?)';
      args.push('%' + from + '%');
      args.push('%' + from + '%');
    }
    if (query.after > 0) {
      clause += ' AND a.published_at >= ?';
      args.push(query.after);
    }
    if (query.before > 0) {
      clause += ' AND a.published_at < ?';
      args.push(query.before);
    }
    return clause;
  }

  /** 片段提取用的关键词（第一个词 / 短语）。 */
  protected snippetTerm(query: SearchQuery): string {
    if (query.phrase.length > 0) {
      return query.phrase;
    }
    return query.terms.length > 0 ? query.terms[0] : '';
  }

  /** 命中片段列：在 plain_text 里找关键词并裁切，找不到退回摘要。 */
  protected snippetColumn(): string {
    return ', CASE' +
      ' WHEN instr(lower(a.plain_text), lower(?)) > 0 THEN substr(a.plain_text,' +
      ' MAX(1, instr(lower(a.plain_text), lower(?)) - 40), ' + SearchConstants.SNIPPET_MAX_CHARS + ')' +
      ' WHEN length(a.summary) > 0 THEN substr(a.summary, 1, ' + SearchConstants.SNIPPET_MAX_CHARS + ')' +
      ' ELSE substr(a.plain_text, 1, ' + SearchConstants.SNIPPET_MAX_CHARS + ') END AS snippet';
  }

  protected async searchFts(store: relationalStore.RdbStore, query: SearchQuery,
    expression: string, offset: number, limit: number): Promise<SearchPage> {
    const countArgs: Array<relationalStore.ValueType> = [expression];
    // FTS5 的 MATCH 左操作数必须是表名，不能是别名，故 FTS 表不加别名。
    const countSql: string = 'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS +
      ' JOIN ' + ArticleDbConstants.TABLE_ARTICLES + ' a ON a.id = ' +
      ArticleDbConstants.TABLE_ARTICLES_FTS + '.article_id' +
      ' WHERE ' + ArticleDbConstants.TABLE_ARTICLES_FTS + ' MATCH ?' + this.filterClause(query, countArgs);
    const total: number = await this.queryCount(store, countSql, countArgs, true);

    const term: string = this.snippetTerm(query);
    const args: Array<relationalStore.ValueType> = [term, term, expression];
    const sql: string = 'SELECT a.id, a.title, a.feed_title, a.published_at, a.is_read, a.is_starred, a.is_saved' +
      this.snippetColumn() +
      ' FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS +
      ' JOIN ' + ArticleDbConstants.TABLE_ARTICLES + ' a ON a.id = ' +
      ArticleDbConstants.TABLE_ARTICLES_FTS + '.article_id' +
      ' WHERE ' + ArticleDbConstants.TABLE_ARTICLES_FTS + ' MATCH ?' + this.filterClause(query, args) +
      ' ORDER BY a.published_at DESC LIMIT ? OFFSET ?';
    args.push(limit);
    args.push(offset);
    const hits: SearchHit[] = await this.queryHits(store, sql, args, true);
    return new SearchPage(hits, total, offset + hits.length < total);
  }

  /**
   * 中文索引路径：MATCH 二元组表达式 + 复核条件。
   * 计数用 COUNT(DISTINCT a.id)、取页用 SELECT DISTINCT：索引里同篇文章理论上只有一行，
   * 但重建中断等异常可能留下重复行，去重后 total 与分页才能保持一致。
   */
  protected async searchCjk(store: relationalStore.RdbStore, query: SearchQuery,
    plan: CjkQueryPlan, offset: number, limit: number): Promise<SearchPage> {
    const countArgs: Array<relationalStore.ValueType> = [plan.expression];
    const countFilter: string = this.filterClause(query, countArgs);
    const countPost: string = postFilterSql(plan, 'a', countArgs);
    // FTS5 的 MATCH 左操作数必须是表名，不能是别名，故中文索引表不加别名。
    const countSql: string = 'SELECT COUNT(DISTINCT a.id) AS c FROM ' +
      ArticleDbConstants.TABLE_ARTICLES_FTS_CJK + ' JOIN ' + ArticleDbConstants.TABLE_ARTICLES +
      ' a ON a.id = ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK + '.article_id' +
      ' WHERE ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK + ' MATCH ?' + countFilter + countPost;
    const total: number = await this.queryCount(store, countSql, countArgs, true);

    const term: string = this.snippetTerm(query);
    const args: Array<relationalStore.ValueType> = [term, term, plan.expression];
    const filter: string = this.filterClause(query, args);
    const post: string = postFilterSql(plan, 'a', args);
    const sql: string = 'SELECT DISTINCT a.id, a.title, a.feed_title, a.published_at,' +
      ' a.is_read, a.is_starred, a.is_saved' + this.snippetColumn() +
      ' FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK +
      ' JOIN ' + ArticleDbConstants.TABLE_ARTICLES + ' a ON a.id = ' +
      ArticleDbConstants.TABLE_ARTICLES_FTS_CJK + '.article_id' +
      ' WHERE ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK + ' MATCH ?' + filter + post +
      ' ORDER BY a.published_at DESC LIMIT ? OFFSET ?';
    args.push(limit);
    args.push(offset);
    const hits: SearchHit[] = await this.queryHits(store, sql, args, true);
    return new SearchPage(hits, total, offset + hits.length < total);
  }

  /** LIKE 降级：分页子串匹配（不依赖分词器，中文一定能命中）。 */
  protected async searchLike(store: relationalStore.RdbStore, query: SearchQuery,
    offset: number, limit: number): Promise<SearchPage> {
    const keyword: string = (query.phrase.length > 0 ? query.phrase : query.terms.join(' ')).trim();
    const hasKeyword: boolean = keyword.length > 0;
    const like: string = '%' + keyword + '%';
    const where: string = hasKeyword
      ? ' WHERE (a.title LIKE ? OR a.summary LIKE ? OR a.plain_text LIKE ? OR a.author LIKE ?)'
      : ' WHERE 1 = 1';
    const countArgs: Array<relationalStore.ValueType> = hasKeyword ? [like, like, like, like] : [];
    const countSql: string = 'SELECT COUNT(*) AS c FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a' +
      where + this.filterClause(query, countArgs);
    const total: number = await this.queryCount(store, countSql, countArgs);

    // 占位符顺序：先 SELECT 片段里的两个关键词，再 WHERE 的四个 LIKE（无关键词时没有 LIKE）。
    const args: Array<relationalStore.ValueType> = [keyword, keyword];
    if (hasKeyword) {
      args.push(like);
      args.push(like);
      args.push(like);
      args.push(like);
    }
    const sql: string = 'SELECT a.id, a.title, a.feed_title, a.published_at, a.is_read, a.is_starred, a.is_saved' +
      this.snippetColumn() +
      ' FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' a' + where + this.filterClause(query, args) +
      ' ORDER BY a.published_at DESC LIMIT ? OFFSET ?';
    args.push(limit);
    args.push(offset);
    const hits: SearchHit[] = await this.queryHits(store, sql, args);
    return new SearchPage(hits, total, offset + hits.length < total);
  }

  /**
   * 计数查询。strict = true 时 SQL 出错直接向上抛（检索路径用，交给 search() 降级 LIKE 并打日志）；
   * 默认 false 保持其它调用点「出错返回 0」的旧行为。
   */
  protected async queryCount(store: relationalStore.RdbStore, sql: string,
    args: Array<relationalStore.ValueType>, strict: boolean = false): Promise<number> {
    try {
      const rs: relationalStore.ResultSet = await store.querySql(sql, args);
      try {
        return rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('c')) : 0;
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'count query failed: %{public}d', error.code);
      if (strict) {
        throw error as Error;
      }
      return 0;
    }
  }

  /**
   * 取页查询。strict = true 时 SQL 出错直接向上抛；默认 false 保持旧行为（出错返回已取到的部分）。
   */
  protected async queryHits(store: relationalStore.RdbStore, sql: string,
    args: Array<relationalStore.ValueType>, strict: boolean = false): Promise<SearchHit[]> {
    const hits: SearchHit[] = [];
    try {
      const rs: relationalStore.ResultSet = await store.querySql(sql, args);
      try {
        while (rs.goToNextRow()) {
          hits.push(new SearchHit(
            rs.getString(rs.getColumnIndex('id')),
            rs.getString(rs.getColumnIndex('title')),
            rs.getString(rs.getColumnIndex('snippet')),
            rs.getString(rs.getColumnIndex('feed_title')),
            rs.getLong(rs.getColumnIndex('published_at')),
            rs.getLong(rs.getColumnIndex('is_read')) === 1,
            rs.getLong(rs.getColumnIndex('is_starred')) === 1,
            rs.getLong(rs.getColumnIndex('is_saved')) === 1));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'search query failed: %{public}d', error.code);
      if (strict) {
        throw error as Error;
      }
    }
    return hits;
  }

  /**
   * 全量重建检索索引：分批（每批 REBUILD_BATCH 条）写入并回调进度，不阻塞阅读（异步分批）。
   */
  async rebuildSearchIndex(onProgress: (done: number, total: number) => void): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    if (!this.ftsReady) {
      await this.createFts();
      if (!this.ftsReady) {
        onProgress(0, 0);
        return;
      }
    }
    try {
      store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS);
      const total: number = await this.countIndexable();
      let done: number = 0;
      onProgress(0, total);
      let offset: number = 0;
      while (offset < total) {
        const rs: relationalStore.ResultSet = await store.querySql(
          'SELECT id, title, summary, plain_text, author FROM ' + ArticleDbConstants.TABLE_ARTICLES +
          ' WHERE canonical_id = \'\' ORDER BY published_at DESC LIMIT ? OFFSET ?',
          [SearchConstants.REBUILD_BATCH, offset]);
        const rows: Array<Array<string>> = [];
        try {
          while (rs.goToNextRow()) {
            rows.push([
              rs.getString(rs.getColumnIndex('id')),
              rs.getString(rs.getColumnIndex('title')),
              rs.getString(rs.getColumnIndex('summary')),
              rs.getString(rs.getColumnIndex('plain_text')),
              rs.getString(rs.getColumnIndex('author'))
            ]);
          }
        } finally {
          rs.close();
        }
        if (rows.length === 0) {
          break;
        }
        store.beginTransaction();
        try {
          for (let i = 0; i < rows.length; i += 1) {
            this.ftsInsert(rows[i][0], rows[i][1], rows[i][2], rows[i][3], rows[i][4]);
          }
          store.commit();
        } catch (inner) {
          store.rollBack();
          throw inner as Error;
        }
        done += rows.length;
        offset += rows.length;
        onProgress(done, total);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'rebuild index failed: %{public}d %{public}s',
        error.code, error.message);
    }
  }

  /**
   * 全量重建中文索引：分批（每批 REBUILD_BATCH 条）+ 每批一个事务，回调进度；不阻塞阅读。
   * 中断（应用被杀）后下次启动会重新构建：先清空再写，保证不产生重复行 / 半截数据被当成完整索引。
   * 失败时保留已写入的部分并刷新条数（诊断可见），检索仍可用（未命中走 LIKE 复核兜底）。
   */
  async rebuildCjkIndex(onProgress: (done: number, total: number) => void): Promise<void> {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    if (!this.cjkReady) {
      this.createCjk();
      if (!this.cjkReady) {
        onProgress(0, 0);
        return;
      }
    }
    try {
      const existing: number = await this.cjkCount();
      if (existing > 0) {
        store.executeSync('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK);
      }
      const total: number = await this.countIndexable();
      let done: number = 0;
      onProgress(0, total);
      let offset: number = 0;
      while (offset < total) {
        const rs: relationalStore.ResultSet = await store.querySql(
          'SELECT id, title, summary, plain_text, content FROM ' + ArticleDbConstants.TABLE_ARTICLES +
          ' WHERE canonical_id = \'\' ORDER BY published_at DESC LIMIT ? OFFSET ?',
          [SearchConstants.REBUILD_BATCH, offset]);
        const rows: Array<Array<string>> = [];
        try {
          while (rs.goToNextRow()) {
            rows.push([
              rs.getString(rs.getColumnIndex('id')),
              rs.getString(rs.getColumnIndex('title')),
              rs.getString(rs.getColumnIndex('summary')),
              rs.getString(rs.getColumnIndex('plain_text')),
              rs.getString(rs.getColumnIndex('content'))
            ]);
          }
        } finally {
          rs.close();
        }
        if (rows.length === 0) {
          break;
        }
        store.beginTransaction();
        try {
          for (let i = 0; i < rows.length; i += 1) {
            this.cjkInsert(rows[i][0], rows[i][1], rows[i][2], this.plainOf(rows[i][3], rows[i][4]));
          }
          store.commit();
        } catch (inner) {
          store.rollBack();
          throw inner as Error;
        }
        done += rows.length;
        offset += rows.length;
        onProgress(done, total);
      }
      this.cjkIndexedCount = await this.cjkCount();
      hilog.info(DOMAIN, TAG, 'CJKIDX cjk rebuilt rows=%{public}d', this.cjkIndexedCount);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      // 重建失败保留旧状态（已写入的部分仍可用），只记日志 + 刷新条数。
      this.cjkIndexedCount = await this.cjkCount();
      hilog.error(DOMAIN, TAG, 'CJKIDX rebuild cjk index failed: %{public}d %{public}s',
        error.code, error.message);
    }
  }

  /** 正文纯文本：优先 plain_text（Reader 已提取），否则从 content 粗略转一次。 */
  protected plainOf(plainText: string, content: string): string {
    return plainText.length > 0 ? plainText : toPlainText(content);
  }

  /** 一篇文档的 CJK token 流：标题 + 摘要 + 正文纯文本，受单篇字符上限约束。 */
  protected gramsOf(title: string, summary: string, plainText: string): string {
    const text: string = title + ' ' + summary + ' ' + plainText;
    return grams(text, SearchConstants.CJK_GRAMS_MAX_CHARS);
  }

  protected ftsInsert(articleId: string, title: string, summary: string,
    plainText: string, author: string): void {
    try {
      const store: relationalStore.RdbStore | undefined = this.store;
      if (store === undefined || !this.ftsReady) {
        return;
      }
      store.executeSync('INSERT INTO ' + ArticleDbConstants.TABLE_ARTICLES_FTS +
        ' (article_id, title, summary, plain_text, author) VALUES (?, ?, ?, ?, ?)',
        [articleId, title, summary, plainText, author]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'fts insert failed: %{public}d %{public}s', error.code, error.message);
    }
  }

  /** 有则更新、无则插入（setReaderHtml / 回填用）。 */
  protected ftsUpsert(articleId: string, title: string, summary: string,
    plainText: string, author: string): void {
    try {
      const store: relationalStore.RdbStore | undefined = this.store;
      if (store === undefined || !this.ftsReady) {
        return;
      }
      store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES_FTS +
        ' SET title = ?, summary = ?, plain_text = ?, author = ? WHERE article_id = ?',
        [title, summary, plainText, author, articleId]);
      if (this.lastChanges() === 0) {
        this.ftsInsert(articleId, title, summary, plainText, author);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'fts upsert failed: %{public}d', error.code);
    }
  }

  protected deleteFtsRows(ids: string[]): void {
    if (!this.ftsReady || ids.length === 0) {
      return;
    }
    for (let i = 0; i < ids.length; i += 1) {
      this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS + ' WHERE article_id = ?', [ids[i]]);
    }
  }

  /**
   * 写一行中文索引（失败只记日志：索引是增强能力，不能影响入库 / 阅读）。
   * 纯英文文章也写一行（grams 为空）：这样索引行数恒等于文章数，
   * 「条数不一致 = 重建被打断」的判断才成立，否则每次启动都会误判为需要重建。
   */
  protected cjkInsert(articleId: string, title: string, summary: string, plainText: string): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || !this.cjkReady) {
      return;
    }
    try {
      const tokenStream: string = this.gramsOf(title, summary, plainText);
      store.executeSync('INSERT INTO ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK +
        ' (article_id, grams) VALUES (?, ?)', [articleId, tokenStream]);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'CJKIDX cjk insert failed: %{public}d %{public}s',
        error.code, error.message);
    }
  }

  /** 有则更新、无则插入（setReaderHtml / 恢复 / 回填用）。 */
  protected cjkUpsert(articleId: string, title: string, summary: string, plainText: string): void {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || !this.cjkReady) {
      return;
    }
    try {
      const tokenStream: string = this.gramsOf(title, summary, plainText);
      store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK +
        ' SET grams = ? WHERE article_id = ?', [tokenStream, articleId]);
      if (this.lastChanges() === 0) {
        store.executeSync('INSERT INTO ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK +
          ' (article_id, grams) VALUES (?, ?)', [articleId, tokenStream]);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'CJKIDX cjk upsert failed: %{public}d %{public}s',
        error.code, error.message);
    }
  }

  protected cjkDeleteRows(ids: string[]): void {
    if (!this.cjkReady || ids.length === 0) {
      return;
    }
    for (let i = 0; i < ids.length; i += 1) {
      this.exec('DELETE FROM ' + ArticleDbConstants.TABLE_ARTICLES_FTS_CJK + ' WHERE article_id = ?',
        [ids[i]]);
    }
  }

}
