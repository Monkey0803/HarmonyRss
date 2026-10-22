/*
 * RemoteCredentials.ets — 远端服务密码的加密存储（Asset Store Kit）。
 *
 * 密码只进 Asset Store（底层由 HUKS 管理），绝不写入 preferences / DB / 日志。
 * 别名固定为 `rss_remote_<accountId>`，访问时机为「首次解锁后」。
 */

import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'RemoteCredentials';
/** Asset Store：别名已存在。 */
const ASSET_DUPLICATED: number = 24000003;

function toBytes(value: string): Uint8Array {
  return new util.TextEncoder().encodeInto(value);
}

function toText(value: Uint8Array): string {
  try {
    return util.TextDecoder.create('utf-8').decodeToString(value);
  } catch (err) {
    return '';
  }
}

export class RemoteCredentials {
  /** 别名：一条账号对应一条资产。 */
  private aliasOf(accountId: string): string {
    return 'rss_remote_' + accountId;
  }

  /** 写入密码；别名已存在时先删再写（覆盖语义）。 */
  async save(accountId: string, password: string): Promise<void> {
    const alias: string = this.aliasOf(accountId);
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, toBytes(alias));
    attributes.set(asset.Tag.SECRET, toBytes(password));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    // 先按覆盖策略尝试；部分实现不支持 OVERWRITE 时按错误码兜底为 remove + add。
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try {
      await asset.add(attributes);
      return;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      if (error.code === ASSET_DUPLICATED) {
        await this.remove(accountId);
        const retry: asset.AssetMap = new Map();
        retry.set(asset.Tag.ALIAS, toBytes(alias));
        retry.set(asset.Tag.SECRET, toBytes(password));
        retry.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
        await asset.add(retry);
        return;
      }
      hilog.error(DOMAIN, TAG, 'asset add failed: %{public}d', error.code);
      throw error as Error;
    }
  }

  /** 读取密码；不存在 / 读取失败返回 undefined（上层按「凭据缺失」提示重新连接）。 */
  async read(accountId: string): Promise<string | undefined> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(this.aliasOf(accountId)));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results.length === 0) {
        return undefined;
      }
      const secret: boolean | number | Uint8Array | undefined = results[0].get(asset.Tag.SECRET);
      if (secret === undefined || !(secret instanceof Uint8Array)) {
        return undefined;
      }
      const text: string = toText(secret);
      return text.length > 0 ? text : undefined;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'asset query failed: %{public}d', error.code);
      return undefined;
    }
  }

  /** 删除密码（退出登录）。资产本来就不存在时静默。 */
  async remove(accountId: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(this.aliasOf(accountId)));
    try {
      await asset.remove(query);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.info(DOMAIN, TAG, 'asset remove skipped: %{public}d', error.code);
    }
  }
}

export const remoteCredentials: RemoteCredentials = new RemoteCredentials();
