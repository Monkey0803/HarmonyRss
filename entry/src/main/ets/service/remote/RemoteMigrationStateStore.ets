/* 订阅迁移模式与「仅远端」停用记录的持久化。 */
import { FeedSource } from '../../model/Feed';
import { RemoteMigrationMode } from '../../model/Remote';
import { remoteAccountStore } from '../RemoteAccountStore';

export const MODE_KEY: string = 'subscription_mode';
const MODE_DISABLED_KEY: string = 'mode_disabled_feeds';

export function isMigrationMode(value: string): boolean {
  return value === RemoteMigrationMode.MERGE || value === RemoteMigrationMode.MIGRATED
    || value === RemoteMigrationMode.REMOTE_ONLY;
}

export class RemoteMigrationStateStore {
  /** 当前订阅模式（未设置 / 脏值返回空串）。 */
  async subscriptionMode(): Promise<string> {
    const value: string = await remoteAccountStore.getState(MODE_KEY);
    return isMigrationMode(value) ? value : '';
  }

  /** 读「仅远端模式」下被停用的源 id（损坏 JSON 一律当空）。 */
  async readModeDisabledIds(): Promise<string[]> {
    const text: string = await remoteAccountStore.getState(MODE_DISABLED_KEY);
    if (text.length === 0) {
      return [];
    }
    try {
      const raw: string[] = JSON.parse(text);
      if (!Array.isArray(raw)) {
        return [];
      }
      const result: string[] = [];
      for (let i = 0; i < raw.length; i += 1) {
        if (typeof raw[i] === 'string' && raw[i].length > 0) {
          result.push(raw[i]);
        }
      }
      return result;
    } catch (err) {
      return [];
    }
  }

  async saveModeDisabledIds(ids: string[]): Promise<void> {
    await remoteAccountStore.setState(MODE_DISABLED_KEY, ids.length > 0 ? JSON.stringify(ids) : '');
  }

  /** 恢复因「仅远端」被停用的源；返回是否有变化。 */
  async restoreModeDisabledFeeds(feeds: FeedSource[]): Promise<boolean> {
    const ids: string[] = await this.readModeDisabledIds();
    if (ids.length === 0) {
      return false;
    }
    const targets: Set<string> = new Set(ids);
    let changed: boolean = false;
    for (let i = 0; i < feeds.length; i += 1) {
      if (targets.has(feeds[i].id) && !feeds[i].enabled) {
        feeds[i].enabled = true;
        changed = true;
      }
    }
    await this.saveModeDisabledIds([]);
    return changed;
  }

}
