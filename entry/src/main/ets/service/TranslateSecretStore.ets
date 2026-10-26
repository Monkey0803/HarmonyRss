/*
 * TranslateSecretStore.ets — 翻译服务 API Key 的安全存储（Asset Store Kit）。
 *
 * Key 只进 Asset Store（HUKS 管理），绝不写入 preferences / DB / 日志 / 备份。
 * 别名固定为 `rss_translate_key`，访问时机为「首次解锁后」。
 */

import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'TranslateSecretStore';
/** Asset Store：别名已存在。 */
const ASSET_DUPLICATED: number = 24000003;
const ALIAS: string = 'rss_translate_key';

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

export class TranslateSecretStore {
  /** 写入 Key；空串等价于删除。 */
  async save(key: string): Promise<void> {
    const text: string = key.trim();
    if (text.length === 0) {
      await this.remove();
      return;
    }
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, toBytes(ALIAS));
    attributes.set(asset.Tag.SECRET, toBytes(text));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try {
      await asset.add(attributes);
      return;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      if (error.code === ASSET_DUPLICATED) {
        await this.remove();
        const retry: asset.AssetMap = new Map();
        retry.set(asset.Tag.ALIAS, toBytes(ALIAS));
        retry.set(asset.Tag.SECRET, toBytes(text));
        retry.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
        await asset.add(retry);
        return;
      }
      hilog.error(DOMAIN, TAG, 'asset add failed: %{public}d', error.code);
      throw error as Error;
    }
  }

  /** 读取 Key；不存在 / 读取失败返回 undefined。 */
  async read(): Promise<string | undefined> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(ALIAS));
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

  /** 是否已配置 Key（界面展示用，不返回 Key 本身）。 */
  async hasKey(): Promise<boolean> {
    const key: string | undefined = await this.read();
    return key !== undefined && key.length > 0;
  }

  /** 删除 Key。资产本来就不存在时静默。 */
  async remove(): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(ALIAS));
    try {
      await asset.remove(query);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.info(DOMAIN, TAG, 'asset remove skipped: %{public}d', error.code);
    }
  }
}

/** 全局唯一实例。 */
export const translateSecretStore: TranslateSecretStore = new TranslateSecretStore();
