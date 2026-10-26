/*
 * HttpClient.ets — 统一网络层（超时 / 重试 / 条件请求 / UA / 代理 / 并发与限流）。
 *
 * 设计目标：
 *   - 调用方只描述「请求什么」（URL、头、body、超时），不再各自 createHttp / 处理异常；
 *   - 非 2xx 不抛错：远端服务需要读取 401 / 404 / 429 的业务语义，统一层只负责传输；
 *   - 网络层失败统一为 HttpError（timeout / network），并区分是否值得重试；
 *   - GET 默认重试 1 次；5xx / 429 指数退避；非幂等方法默认不重试（调用方可显式开启）；
 *   - 全局并发上限（默认 4），可按请求设置同主机最小请求间隔，避免抓取 / 图片 / 同步互相打爆。
 *
 * 纯函数（backoffMs / hostKeyOf / shouldRetryStatus / parseRetryAfterMs）单独导出，便于单测。
 */

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'HttpClient';

/** 平台错误码 = 2300000 + curl 错误码；28 是操作超时。 */
const HTTP_ERROR_BASE: number = 2300000;
const CURL_TIMEOUT: number = 28;

/** 统一默认值。 */
export class HttpDefaults {
  /** 建立连接超时（毫秒）。 */
  static readonly CONNECT_TIMEOUT_MS: number = 8000;
  /** 读取超时（毫秒）。 */
  static readonly READ_TIMEOUT_MS: number = 15000;
  /** 同时进行的请求数上限。 */
  static readonly MAX_CONCURRENT: number = 4;
  /** GET 默认重试次数（不含首次请求）。 */
  static readonly MAX_RETRIES: number = 1;
  /** 首次退避（毫秒）。 */
  static readonly BASE_BACKOFF_MS: number = 400;
  /** 退避上限（毫秒）。 */
  static readonly MAX_BACKOFF_MS: number = 4000;
  /** Retry-After 等待上限（毫秒），避免被服务端要求长时间挂起。 */
  static readonly MAX_RETRY_AFTER_MS: number = 10000;
  /** 默认 User-Agent：站点会据此给出不同响应，统一标识便于排查。 */
  static readonly USER_AGENT: string = 'HarmonyRss/1.0 (HarmonyOS)';
}

/** 请求方法（不把 @kit.NetworkKit 的枚举泄漏给调用方）。 */
export enum HttpMethod {
  GET,
  POST,
  HEAD
}

/** 网络层错误分类。 */
export enum HttpErrorKind {
  TIMEOUT = 'timeout',
  NETWORK = 'network'
}

/** 统一网络错误：保留原始错误码与是否可重试。 */
export class HttpError extends Error {
  readonly kind: HttpErrorKind;
  /** 平台原始错误码（0 表示未知）。 */
  readonly causeCode: number;
  /** TLS / 证书类错误重试无意义。 */
  readonly retriable: boolean;

  constructor(kind: HttpErrorKind, message: string, causeCode: number, retriable: boolean) {
    super(message);
    this.kind = kind;
    this.causeCode = causeCode;
    this.retriable = retriable;
  }
}

/** 一次请求的可选参数。 */
export class HttpOptions {
  /** 额外请求头；默认 User-Agent 只在调用方没给时补。 */
  headers: Record<string, string> = {};
  /** 请求体（POST 用）。 */
  body: string = '';
  /** 连接超时（毫秒）；<= 0 用默认值。 */
  connectTimeoutMs: number = 0;
  /** 读取超时（毫秒）；<= 0 用默认值。 */
  readTimeoutMs: number = 0;
  /** true 时返回二进制（bytes），false 时返回文本（text）。 */
  binary: boolean = false;
  /** 重试次数；-1 表示按方法取默认（GET/HEAD 默认 1，其它 0）。 */
  maxRetries: number = -1;
  /** 5xx / 429 是否重试（默认 true）。 */
  retryServerErrors: boolean = true;
  /** 同主机两次请求开始的最小间隔（毫秒）；0 表示不限流。 */
  minIntervalMs: number = 0;
  /** 是否走系统代理（默认 true）。 */
  usingProxy: boolean = true;
}

/** 响应：文本与二进制按请求类型二选一。 */
export class HttpResponse {
  readonly status: number;
  readonly text: string;
  readonly bytes: Uint8Array | undefined;
  private readonly headers: Record<string, string>;

  constructor(status: number, headers: Record<string, string>, text: string,
    bytes: Uint8Array | undefined) {
    this.status = status;
    this.headers = headers;
    this.text = text;
    this.bytes = bytes;
  }

  /** 大小写不敏感地读响应头（不存在的返回空串）。 */
  header(name: string): string {
    const exact: string | undefined = this.headers[name];
    if (exact !== undefined && exact.length > 0) {
      return exact.trim();
    }
    const target: string = name.toLowerCase();
    const keys: string[] = Object.keys(this.headers);
    for (let i = 0; i < keys.length; i += 1) {
      const key: string = keys[i];
      if (key.toLowerCase() !== target) {
        continue;
      }
      const value: string | undefined = this.headers[key];
      if (value !== undefined && value.length > 0) {
        return value.trim();
      }
    }
    return '';
  }
}

// ---- 纯函数（可单测） ----

/** 指数退避：base * 2^attempt，夹到上限；attempt < 0 按 0 处理。 */
export function backoffMs(attempt: number, baseMs: number = HttpDefaults.BASE_BACKOFF_MS,
  maxMs: number = HttpDefaults.MAX_BACKOFF_MS): number {
  const base: number = Number.isFinite(baseMs) && baseMs > 0 ? baseMs : HttpDefaults.BASE_BACKOFF_MS;
  const max: number = Number.isFinite(maxMs) && maxMs > 0 ? maxMs : HttpDefaults.MAX_BACKOFF_MS;
  const safeAttempt: number = Number.isFinite(attempt) && attempt > 0 ? Math.floor(attempt) : 0;
  let wait: number = base;
  for (let i = 0; i < safeAttempt; i += 1) {
    wait = wait * 2;
    if (wait >= max) {
      return max;
    }
  }
  return Math.min(max, wait);
}

/** URL → 限流键（scheme://host:port，小写；非法串返回空串）。 */
export function hostKeyOf(url: string): string {
  const schemeEnd: number = url.indexOf('://');
  if (schemeEnd < 0) {
    return '';
  }
  const authorityStart: number = schemeEnd + 3;
  let authorityEnd: number = url.length;
  const slash: number = url.indexOf('/', authorityStart);
  if (slash >= 0) {
    authorityEnd = slash;
  }
  const question: number = url.indexOf('?', authorityStart);
  if (question >= 0 && question < authorityEnd) {
    authorityEnd = question;
  }
  const hash: number = url.indexOf('#', authorityStart);
  if (hash >= 0 && hash < authorityEnd) {
    authorityEnd = hash;
  }
  let authority: string = url.substring(authorityStart, authorityEnd);
  // 去掉 user:pass@（保留 host:port）。
  const at: number = authority.lastIndexOf('@');
  if (at >= 0) {
    authority = authority.substring(at + 1);
  }
  return authority.toLowerCase();
}

/** 这些状态码值得重试：429 与 5xx。 */
export function shouldRetryStatus(status: number): boolean {
  return status === 429 || status >= 500;
}

/**
 * 解析 Retry-After（秒）；非法 / 缺失时退回 fallback，并夹到上限。
 * 只支持数字秒（HTTP-date 形式在 RSS 场景极少见，按 fallback 处理）。
 */
export function parseRetryAfterMs(value: string, fallbackMs: number,
  maxMs: number = HttpDefaults.MAX_RETRY_AFTER_MS): number {
  const fallback: number = Number.isFinite(fallbackMs) && fallbackMs > 0 ? fallbackMs : 0;
  const max: number = Number.isFinite(maxMs) && maxMs > 0 ? maxMs : HttpDefaults.MAX_RETRY_AFTER_MS;
  const text: string = value.trim();
  if (text.length === 0) {
    return fallback;
  }
  const seconds: number = Number(text);
  if (!Number.isFinite(seconds) || seconds < 0) {
    return fallback;
  }
  return Math.min(max, Math.round(seconds * 1000));
}

/** 条件请求头：有校验值才加（空串表示没有）。 */
export function setConditionalHeaders(headers: Record<string, string>, etag: string,
  lastModified: string): void {
  if (etag.length > 0) {
    headers['If-None-Match'] = etag;
  }
  if (lastModified.length > 0) {
    headers['If-Modified-Since'] = lastModified;
  }
}

/** 方法 → 默认重试次数：GET/HEAD 1 次，其它 0 次（避免非幂等写操作重复执行）。 */
export function defaultRetries(method: HttpMethod): number {
  return method === HttpMethod.GET || method === HttpMethod.HEAD ? HttpDefaults.MAX_RETRIES : 0;
}

/** 延时（毫秒）。 */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

/** 业务方法 → 平台枚举。 */
function platformMethod(method: HttpMethod): http.RequestMethod {
  if (method === HttpMethod.POST) {
    return http.RequestMethod.POST;
  }
  if (method === HttpMethod.HEAD) {
    return http.RequestMethod.HEAD;
  }
  return http.RequestMethod.GET;
}

/** 原始异常 → HttpError（区分超时 / TLS / 其它网络错误）。 */
function toHttpError(err: Object): HttpError {
  const error: BusinessError = err as BusinessError;
  const code: number = typeof error.code === 'number' ? error.code : 0;
  const message: string = error.message !== undefined && error.message.length > 0
    ? error.message : 'network failed';
  const lower: string = message.toLowerCase();
  const tls: boolean = lower.indexOf('certificate') >= 0 || lower.indexOf('ssl') >= 0 ||
    lower.indexOf('tls') >= 0 || code === 2300060 || code === 2300061;
  const timeout: boolean = code === HTTP_ERROR_BASE + CURL_TIMEOUT ||
    lower.indexOf('timeout') >= 0 || lower.indexOf('timed out') >= 0;
  return new HttpError(timeout ? HttpErrorKind.TIMEOUT : HttpErrorKind.NETWORK, message, code, !tls);
}

export class HttpClient {
  /** 正在进行的请求数。 */
  private active: number = 0;
  /** 并发已满时排队的唤醒函数。 */
  private waiters: Array<() => void> = [];
  /** 主机 → 上次请求开始时间（毫秒）。 */
  private hostLastStart: Map<string, number> = new Map<string, number>();

  /** 取得一个并发槽（满了就排队）。 */
  private acquire(): Promise<void> {
    if (this.active < HttpDefaults.MAX_CONCURRENT) {
      this.active += 1;
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void) => {
      this.waiters.push(resolve);
    });
  }

  /** 释放并发槽：有排队者就直接移交，不减少 active。 */
  private release(): void {
    const next: (() => void) | undefined = this.waiters.shift();
    if (next !== undefined) {
      next();
      return;
    }
    if (this.active > 0) {
      this.active -= 1;
    }
  }

  /** 同主机最小间隔：必要时等待，然后记录本次开始时间。 */
  private async throttleHost(hostKey: string, minIntervalMs: number): Promise<void> {
    if (hostKey.length === 0 || !Number.isFinite(minIntervalMs) || minIntervalMs <= 0) {
      return;
    }
    const last: number = this.hostLastStart.get(hostKey) ?? 0;
    const wait: number = last + minIntervalMs - Date.now();
    if (wait > 0) {
      await delay(wait);
    }
    this.hostLastStart.set(hostKey, Date.now());
  }

  /** 补默认头（只在调用方没设置时）。 */
  private buildHeaders(source: Record<string, string>): Record<string, string> {
    const headers: Record<string, string> = {};
    let hasUserAgent: boolean = false;
    const keys: string[] = Object.keys(source);
    for (let i = 0; i < keys.length; i += 1) {
      const key: string = keys[i];
      headers[key] = source[key];
      if (key.toLowerCase() === 'user-agent') {
        hasUserAgent = true;
      }
    }
    if (!hasUserAgent) {
      headers['User-Agent'] = HttpDefaults.USER_AGENT;
    }
    return headers;
  }

  /** 发一次请求（不含重试 / 限流）。 */
  private async sendOnce(method: HttpMethod, url: string, options: HttpOptions): Promise<HttpResponse> {
    const connectTimeout: number = options.connectTimeoutMs > 0
      ? options.connectTimeoutMs : HttpDefaults.CONNECT_TIMEOUT_MS;
    const readTimeout: number = options.readTimeoutMs > 0
      ? options.readTimeoutMs : HttpDefaults.READ_TIMEOUT_MS;
    const header: Record<string, string> = this.buildHeaders(options.headers);
    const requestOptions: http.HttpRequestOptions = {
      method: platformMethod(method),
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      expectDataType: options.binary ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
      header: header,
      usingProxy: options.usingProxy
    };
    if (options.body.length > 0) {
      requestOptions.extraData = options.body;
    }
    const request: http.HttpRequest = http.createHttp();
    try {
      let response: http.HttpResponse;
      try {
        response = await request.request(url, requestOptions);
      } catch (err) {
        throw toHttpError(err);
      }
      const headers: Record<string, string> = response.header as Record<string, string>;
      if (options.binary) {
        const raw: string | Object | ArrayBuffer = response.result;
        const bytes: Uint8Array | undefined =
          raw instanceof ArrayBuffer ? new Uint8Array(raw) : undefined;
        return new HttpResponse(response.responseCode, headers, '', bytes);
      }
      const raw: string | Object | ArrayBuffer = response.result;
      const text: string = typeof raw === 'string' ? raw : '';
      return new HttpResponse(response.responseCode, headers, text, undefined);
    } finally {
      request.destroy();
    }
  }

  /**
   * 发请求（带并发 / 限流 / 重试）。
   * 非 2xx 原样返回；网络失败抛 HttpError。
   */
  async request(method: HttpMethod, url: string, options: HttpOptions = new HttpOptions()): Promise<HttpResponse> {
    const retries: number = options.maxRetries >= 0
      ? Math.floor(options.maxRetries) : defaultRetries(method);
    const hostKey: string = hostKeyOf(url);
    let attempt: number = 0;
    while (true) {
      let retryAfter: number = -1;
      await this.acquire();
      try {
        await this.throttleHost(hostKey, options.minIntervalMs);
        try {
          const response: HttpResponse = await this.sendOnce(method, url, options);
          if (options.retryServerErrors && attempt < retries && shouldRetryStatus(response.status)) {
            const fallback: number = backoffMs(attempt);
            retryAfter = parseRetryAfterMs(response.header('Retry-After'), fallback);
          } else {
            return response;
          }
        } catch (err) {
          const failure: HttpError = err instanceof HttpError ? err : toHttpError(err);
          if (attempt >= retries || !failure.retriable) {
            throw failure;
          }
          hilog.warn(DOMAIN, TAG, 'request failed (attempt %{public}d): %{public}s',
            attempt + 1, failure.message);
          retryAfter = backoffMs(attempt);
        }
      } finally {
        this.release();
      }
      await delay(retryAfter >= 0 ? retryAfter : backoffMs(attempt));
      attempt += 1;
    }
  }

  /** GET 文本。 */
  async getText(url: string, options: HttpOptions = new HttpOptions()): Promise<HttpResponse> {
    options.binary = false;
    return await this.request(HttpMethod.GET, url, options);
  }

  /** GET 二进制（图片等）。 */
  async getBytes(url: string, options: HttpOptions = new HttpOptions()): Promise<HttpResponse> {
    options.binary = true;
    return await this.request(HttpMethod.GET, url, options);
  }
}

/** 全局唯一实例。 */
export const httpClient: HttpClient = new HttpClient();
