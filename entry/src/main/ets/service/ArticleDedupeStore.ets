/* Canonical promotion and group queries on the shared article connection. */
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ArticleDbConstants } from '../common/constants/RssConstants';
import { DedupeCandidate, GroupSource } from '../model/Dedupe';
import { DedupeService } from './DedupeService';
import { DOMAIN, TAG, DEDUPE_KEY_BATCH, placeholders } from './ArticleSchema';

export class ArticleDedupeStore {
  private store: relationalStore.RdbStore | undefined;

  constructor(store: relationalStore.RdbStore | undefined) {
    this.store = store;
  }

  public promoteBeforeRemoval(ids: string[]): string[] {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined || ids.length === 0) {
      return [];
    }
    const removing: Set<string> = new Set<string>();
    const roots: string[] = [];
    try {
      // 一次查出本批的挂靠状态：只有 canonical_id 为空的主条才需要提升。
      for (let start = 0; start < ids.length; start += DEDUPE_KEY_BATCH) {
        const slice: string[] = ids.slice(start, start + DEDUPE_KEY_BATCH);
        for (let i = 0; i < slice.length; i += 1) {
          removing.add(slice[i]);
        }
        const rs: relationalStore.ResultSet = store.querySqlSync(
          'SELECT id, canonical_id FROM ' + ArticleDbConstants.TABLE_ARTICLES +
          ' WHERE id IN (' + placeholders(slice.length) + ')', slice);
        try {
          while (rs.goToNextRow()) {
            if (rs.getString(rs.getColumnIndex('canonical_id')).length === 0) {
              roots.push(rs.getString(rs.getColumnIndex('id')));
            }
          }
        } finally {
          rs.close();
        }
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'promote prepare failed: %{public}d', error.code);
      return [];
    }
    return this.promoteRoots(store, roots, removing);
  }

  public promoteRoots(store: relationalStore.RdbStore, roots: string[],
    removing: Set<string>): string[] {
    const promoted: string[] = [];
    if (roots.length === 0) {
      return promoted;
    }
    try {
      // 按批取出这些主条的成员：几千条清理也只需要十几次查询。
      const membersByRoot: Map<string, DedupeCandidate[]> = new Map<string, DedupeCandidate[]>();
      for (let start = 0; start < roots.length; start += DEDUPE_KEY_BATCH) {
        const slice: string[] = roots.slice(start, start + DEDUPE_KEY_BATCH);
        const rs: relationalStore.ResultSet = store.querySqlSync(
          'SELECT id, feed_id, canonical_id, link_key, title_key, published_at FROM ' +
          ArticleDbConstants.TABLE_ARTICLES +
          ' WHERE canonical_id IN (' + placeholders(slice.length) + ')', slice);
        try {
          while (rs.goToNextRow()) {
            const root: string = rs.getString(rs.getColumnIndex('canonical_id'));
            const candidate: DedupeCandidate = new DedupeCandidate(
              rs.getString(rs.getColumnIndex('id')),
              rs.getString(rs.getColumnIndex('feed_id')),
              root,
              rs.getString(rs.getColumnIndex('link_key')),
              rs.getString(rs.getColumnIndex('title_key')),
              rs.getLong(rs.getColumnIndex('published_at')));
            const bucket: DedupeCandidate[] | undefined = membersByRoot.get(root);
            if (bucket === undefined) {
              membersByRoot.set(root, [candidate]);
            } else {
              bucket.push(candidate);
            }
          }
        } finally {
          rs.close();
        }
      }
      for (let i = 0; i < roots.length; i += 1) {
        const root: string = roots[i];
        const members: DedupeCandidate[] | undefined = membersByRoot.get(root);
        const remaining: DedupeCandidate[] = [];
        if (members !== undefined) {
          for (let j = 0; j < members.length; j += 1) {
            if (!removing.has(members[j].id)) {
              remaining.push(members[j]);
            }
          }
        }
        const nextRoot: string = DedupeService.pickPromotion(remaining);
        if (nextRoot.length === 0) {
          continue;
        }
        store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
          ' SET canonical_id = \'\' WHERE id = ?', [nextRoot]);
        store.executeSync('UPDATE ' + ArticleDbConstants.TABLE_ARTICLES +
          ' SET canonical_id = ? WHERE canonical_id = ? AND id <> ?', [nextRoot, root, nextRoot]);
        promoted.push(nextRoot);
        hilog.info(DOMAIN, TAG, 'canonical promoted, group size=%{public}d',
          remaining.length + 1);
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'promote canonical failed: %{public}d', error.code);
    }
    return promoted;
  }

  public canonicalOfSync(store: relationalStore.RdbStore, id: string): string {
    const rs: relationalStore.ResultSet = store.querySqlSync(
      'SELECT canonical_id FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?', [id]);
    try {
      return rs.goToNextRow() ? rs.getString(rs.getColumnIndex('canonical_id')) : '';
    } finally {
      rs.close();
    }
  }

  public rowExistsSync(store: relationalStore.RdbStore, id: string): boolean {
    const rs: relationalStore.ResultSet = store.querySqlSync(
      'SELECT 1 AS ok FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?', [id]);
    try {
      return rs.goToNextRow();
    } finally {
      rs.close();
    }
  }

  async groupIdsOf(id: string): Promise<string[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: string[] = [];
    if (store === undefined || id.length === 0) {
      return result;
    }
    try {
      const root: string = await this.rootOf(store, id);
      const args: Array<relationalStore.ValueType> = [root, root];
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE id = ? OR canonical_id = ? ORDER BY published_at ASC, id ASC', args);
      try {
        while (rs.goToNextRow()) {
          result.push(rs.getString(rs.getColumnIndex('id')));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'groupIdsOf failed: %{public}d', error.code);
      return [id];
    }
    if (result.length === 0) {
      result.push(id);
    }
    return result;
  }

  async loadGroupSources(articleId: string): Promise<GroupSource[]> {
    const store: relationalStore.RdbStore | undefined = this.store;
    const result: GroupSource[] = [];
    if (store === undefined || articleId.length === 0) {
      return result;
    }
    try {
      const root: string = await this.rootOf(store, articleId);
      const args: Array<relationalStore.ValueType> = [root, root];
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT id, feed_title, link, published_at FROM ' + ArticleDbConstants.TABLE_ARTICLES +
        ' WHERE id = ? OR canonical_id = ? ORDER BY published_at ASC, id ASC', args);
      try {
        while (rs.goToNextRow()) {
          result.push(new GroupSource(
            rs.getString(rs.getColumnIndex('id')),
            rs.getString(rs.getColumnIndex('feed_title')),
            rs.getString(rs.getColumnIndex('link')),
            rs.getLong(rs.getColumnIndex('published_at'))));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'loadGroupSources failed: %{public}d', error.code);
    }
    return result;
  }

  private async rootOf(store: relationalStore.RdbStore, id: string): Promise<string> {
    let current: string = id;
    for (let depth = 0; depth < 8; depth += 1) {
      const args: Array<relationalStore.ValueType> = [current];
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT canonical_id FROM ' + ArticleDbConstants.TABLE_ARTICLES + ' WHERE id = ?', args);
      let next: string = '';
      let found: boolean = false;
      try {
        found = rs.goToNextRow();
        if (found) {
          next = rs.getString(rs.getColumnIndex('canonical_id'));
        }
      } finally {
        rs.close();
      }
      if (!found || next.length === 0 || next === current) {
        break;
      }
      current = next;
    }
    return current;
  }
}
