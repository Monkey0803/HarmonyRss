/*
 * RemoteAccountViewModel.ets — 远端账号页的状态与动作（账号表单 / 连接 / 同步 / 退出）。
 *
 * 视图只读这里的 @Trace 字段并上报事件；协议与存储逻辑都在 RemoteSyncService / Store。
 */

import {
  RemoteAccount,
  RemoteConnectResult,
  RemoteError,
  RemoteErrorCode,
  SyncResult,
  SyncStatus
} from '../model/Remote';
import { remoteSyncService } from '../service/remote/RemoteSyncService';
import { DateUtil } from '../common/utils/DateUtil';

@ObservedV2
export class RemoteAccountViewModel {
  @Trace baseUrl: string = '';
  @Trace username: string = '';
  @Trace password: string = '';
  /** 是否允许明文 http（默认关，需用户显式允许）。 */
  @Trace allowHttp: boolean = false;
  @Trace account: RemoteAccount | undefined = undefined;
  @Trace status: SyncStatus = new SyncStatus(0, 0, 0, '', 'idle');
  /** 最近一次动作的错误码（NONE 表示无错误）。 */
  @Trace errorCode: RemoteErrorCode = RemoteErrorCode.NONE;
  @Trace connecting: boolean = false;
  @Trace syncing: boolean = false;
  /** 连接成功后的远端订阅数（首次同步前展示）。 */
  @Trace feedCount: number = 0;
  /** 首次同步失败等非致命提示的错误码。 */
  @Trace warningCode: RemoteErrorCode = RemoteErrorCode.NONE;
  @Trace initialized: boolean = false;

  /** 进入页面：恢复账号并刷新状态。 */
  async init(): Promise<void> {
    if (this.initialized) {
      await this.refresh();
      return;
    }
    this.initialized = true;
    const account: RemoteAccount | undefined = await remoteSyncService.ensureAccount(true);
    this.applyAccount(account);
    await this.refresh();
  }

  /** 已连接时回填表单（地址 / 用户名），密码永远不回填。 */
  private applyAccount(account: RemoteAccount | undefined): void {
    this.account = account;
    if (account !== undefined) {
      if (this.baseUrl.length === 0) {
        this.baseUrl = account.baseUrl;
      }
      if (this.username.length === 0) {
        this.username = account.username;
      }
      this.allowHttp = account.baseUrl.toLowerCase().startsWith('http://');
    }
  }

  /** 刷新账号与同步状态。 */
  async refresh(): Promise<void> {
    const account: RemoteAccount | undefined = await remoteSyncService.ensureAccount(true);
    this.applyAccount(account);
    this.status = await remoteSyncService.status();
    this.feedCount = await remoteSyncService.remoteFeedCount();
  }

  /** 连接服务；返回是否成功（失败时 errorCode 已设置）。 */
  async connect(): Promise<boolean> {
    if (this.connecting) {
      return false;
    }
    this.errorCode = RemoteErrorCode.NONE;
    this.warningCode = RemoteErrorCode.NONE;
    this.connecting = true;
    try {
      const result: RemoteConnectResult = await remoteSyncService.connect(
        this.baseUrl, this.username, this.password, this.allowHttp);
      if (!result.ok) {
        this.errorCode = result.code;
        return false;
      }
      this.feedCount = result.feedCount;
      // 连接成功后立刻清掉内存里的密码（已进 Asset Store）。
      this.password = '';
      this.warningCode = result.syncError.length > 0
        ? this.codeOfText(result.syncError) : RemoteErrorCode.NONE;
      await this.refresh();
      this.syncing = false;
      return true;
    } finally {
      this.connecting = false;
    }
  }

  /** 立即同步；失败时返回 undefined 并设置 errorCode。 */
  async syncNow(): Promise<SyncResult | undefined> {
    if (this.syncing) {
      return undefined;
    }
    this.syncing = true;
    this.errorCode = RemoteErrorCode.NONE;
    try {
      const result: SyncResult = await remoteSyncService.syncNow();
      await this.refresh();
      return result;
    } catch (err) {
      this.errorCode = err instanceof RemoteError ? err.code : RemoteErrorCode.SERVER;
      await this.refresh();
      return undefined;
    } finally {
      this.syncing = false;
    }
  }

  /** 退出登录；clearSyncData = true 时一并清除映射 / 队列 / 游标。 */
  async logout(clearSyncData: boolean): Promise<void> {
    await remoteSyncService.logout(clearSyncData);
    this.account = undefined;
    this.password = '';
    this.feedCount = 0;
    this.errorCode = RemoteErrorCode.NONE;
    this.warningCode = RemoteErrorCode.NONE;
    await this.refresh();
  }

  /** 当前是否已连接。 */
  isConnected(): boolean {
    return this.account !== undefined;
  }

  /** 错误码 → 文案资源。 */
  errorText(code: string): ResourceStr {
    if (code === RemoteErrorCode.NETWORK) {
      return $r('app.string.remote_error_network');
    }
    if (code === RemoteErrorCode.TLS) {
      return $r('app.string.remote_error_tls');
    }
    if (code === RemoteErrorCode.AUTH) {
      return $r('app.string.remote_error_auth');
    }
    if (code === RemoteErrorCode.API_DISABLED) {
      return $r('app.string.remote_error_api');
    }
    if (code === RemoteErrorCode.RATE_LIMIT) {
      return $r('app.string.remote_error_rate');
    }
    if (code === RemoteErrorCode.PARSE) {
      return $r('app.string.remote_error_parse');
    }
    if (code === RemoteErrorCode.INSECURE_HTTP) {
      return $r('app.string.remote_error_insecure');
    }
    if (code === RemoteErrorCode.EMPTY) {
      return $r('app.string.remote_error_empty');
    }
    if (code === RemoteErrorCode.BUSY) {
      return $r('app.string.remote_error_busy');
    }
    if (code === RemoteErrorCode.NOT_CONNECTED) {
      return $r('app.string.remote_error_not_connected');
    }
    return $r('app.string.remote_error_server');
  }

  /** 同步阶段 → 文案资源。 */
  phaseText(phase: string): ResourceStr {
    if (phase === 'feeds') {
      return $r('app.string.remote_phase_feeds');
    }
    if (phase === 'articles') {
      return $r('app.string.remote_phase_articles');
    }
    if (phase === 'push') {
      return $r('app.string.remote_phase_push');
    }
    if (phase === 'pull') {
      return $r('app.string.remote_phase_pull');
    }
    if (phase === 'done') {
      return $r('app.string.remote_phase_done');
    }
    return $r('app.string.remote_sync_now');
  }

  /** 最近同步时间文案（未同步时返回「尚未同步」）。 */
  lastSyncText(): ResourceStr {
    if (this.status.lastSyncAt <= 0) {
      return $r('app.string.remote_status_never');
    }
    return DateUtil.format(this.status.lastSyncAt);
  }

  private codeOfText(value: string): RemoteErrorCode {
    if (value === RemoteErrorCode.NETWORK) {
      return RemoteErrorCode.NETWORK;
    }
    if (value === RemoteErrorCode.TLS) {
      return RemoteErrorCode.TLS;
    }
    if (value === RemoteErrorCode.AUTH) {
      return RemoteErrorCode.AUTH;
    }
    if (value === RemoteErrorCode.API_DISABLED) {
      return RemoteErrorCode.API_DISABLED;
    }
    if (value === RemoteErrorCode.RATE_LIMIT) {
      return RemoteErrorCode.RATE_LIMIT;
    }
    if (value === RemoteErrorCode.PARSE) {
      return RemoteErrorCode.PARSE;
    }
    if (value === RemoteErrorCode.INSECURE_HTTP) {
      return RemoteErrorCode.INSECURE_HTTP;
    }
    if (value === RemoteErrorCode.EMPTY) {
      return RemoteErrorCode.EMPTY;
    }
    if (value === RemoteErrorCode.BUSY) {
      return RemoteErrorCode.BUSY;
    }
    if (value === RemoteErrorCode.NOT_CONNECTED) {
      return RemoteErrorCode.NOT_CONNECTED;
    }
    return RemoteErrorCode.SERVER;
  }
}

export const remoteAccountViewModel: RemoteAccountViewModel = new RemoteAccountViewModel();
