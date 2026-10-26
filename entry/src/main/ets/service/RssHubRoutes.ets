/*
 * RssHubRoutes.ets — 从普通站点 / 个人主页地址推导 RSSHub 路由（纯函数）。
 *
 * 设计取舍：
 *   - 只覆盖路由稳定、识别成本低的常见站点；不猜不存在的路由，避免「生成了但订阅失败」。
 *   - 生成结果只是候选，仍走用户确认后的 addFeed（真实抓取一次校验）。
 *   - RSSHub 实例可配置（公共实例可能限流，允许自建域名）。
 */

import { url } from '@kit.ArkTS';

/** 默认 RSSHub 实例。 */
export const DEFAULT_RSSHUB_BASE: string = 'https://rsshub.app';

/** 一条候选路由。kind 是语义 id，界面负责映射文案。 */
export class RssHubSuggestion {
  readonly kind: string;
  /** 以 / 开头的路由路径（不含实例域名）。 */
  readonly route: string;
  /** 拼好实例域名的完整订阅地址。 */
  readonly url: string;

  constructor(kind: string, route: string, url: string) {
    this.kind = kind;
    this.route = route;
    this.url = url;
  }
}

/** 语义 kind 常量。 */
export class RssHubKind {
  static readonly GITHUB_COMMITS: string = 'github_commits';
  static readonly GITHUB_RELEASES: string = 'github_releases';
  static readonly GITHUB_ISSUES: string = 'github_issues';
  static readonly BILIBILI_VIDEO: string = 'bilibili_video';
  static readonly BILIBILI_USER: string = 'bilibili_user';
  static readonly YOUTUBE_CHANNEL: string = 'youtube_channel';
  static readonly YOUTUBE_USER: string = 'youtube_user';
  static readonly TWITTER_USER: string = 'twitter_user';
  static readonly WEIBO_USER: string = 'weibo_user';
  static readonly ZHIHU_USER: string = 'zhihu_user';
  static readonly JIANSHU_USER: string = 'jianshu_user';
  static readonly INSTAGRAM_USER: string = 'instagram_user';
  static readonly DOUYIN_USER: string = 'douyin_user';
  static readonly MEDIUM_USER: string = 'medium_user';
}

/** 主机名是否为某域名或其子域。 */
function isHost(host: string, domain: string): boolean {
  return host === domain || host.endsWith('.' + domain);
}

/** 去掉首尾空白与末尾斜杠，缺 scheme 时补 https；非法返回空串。 */
export function normalizeRssHubBase(raw: string): string {
  const trimmed: string = raw.trim();
  if (trimmed.length === 0) {
    return DEFAULT_RSSHUB_BASE;
  }
  let value: string = trimmed;
  if (value.indexOf('://') < 0) {
    value = 'https://' + value;
  }
  try {
    const parsed: url.URL = new url.URL(value);
    const host: string = parsed.hostname;
    if (host.length === 0) {
      return DEFAULT_RSSHUB_BASE;
    }
    let path: string = parsed.pathname;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path === '/') {
      path = '';
    }
    return parsed.protocol + '//' + host + path;
  } catch (err) {
    return DEFAULT_RSSHUB_BASE;
  }
}

/** 把普通站点地址归一成 URL；失败返回 undefined。 */
function parseInput(raw: string): url.URL | undefined {
  const trimmed: string = raw.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  let value: string = trimmed;
  if (value.indexOf('://') < 0) {
    value = 'https://' + value;
  }
  try {
    const parsed: url.URL = new url.URL(value);
    if (parsed.hostname.length === 0) {
      return undefined;
    }
    return parsed;
  } catch (err) {
    return undefined;
  }
}

/** 路径分段（去空段）。 */
function segmentsOf(parsed: url.URL): string[] {
  const raw: string[] = parsed.pathname.split('/');
  const result: string[] = [];
  for (let i = 0; i < raw.length; i += 1) {
    if (raw[i].length > 0) {
      result.push(raw[i]);
    }
  }
  return result;
}

function safeSegment(value: string): boolean {
  return /^[A-Za-z0-9._@%-]+$/.test(value);
}

function joinUrl(base: string, route: string): string {
  return normalizeRssHubBase(base) + route;
}

/** GitHub 上不作为用户名的保留路径。 */
const GITHUB_RESERVED: string[] = [
  'about', 'collections', 'explore', 'features', 'login', 'marketplace', 'notifications',
  'orgs', 'pricing', 'search', 'settings', 'sponsors', 'topics', 'trending'
];

/** YouTube 上不作为用户名的保留路径。 */
const YOUTUBE_RESERVED: string[] = [
  'about', 'account', 'feed', 'gaming', 'premium', 'results', 'shorts', 'signin', 'watch'
];

/** Twitter / X 上不作为用户名的保留路径。 */
const TWITTER_RESERVED: string[] = [
  'explore', 'hashtag', 'home', 'i', 'intent', 'login', 'search', 'settings', 'share', 'signup'
];

export class RssHubRoutes {
  /** 生成候选路由；不支持的站点返回空数组。 */
  static suggest(rawInput: string, base: string): RssHubSuggestion[] {
    const parsed: url.URL | undefined = parseInput(rawInput);
    if (parsed === undefined) {
      return [];
    }
    const host: string = parsed.hostname.toLowerCase();
    const segments: string[] = segmentsOf(parsed);
    const suggestions: RssHubSuggestion[] = [];
    const seen: Set<string> = new Set();

    const add = (kind: string, route: string): void => {
      if (route.length === 0 || seen.has(route)) {
        return;
      }
      seen.add(route);
      suggestions.push(new RssHubSuggestion(kind, route, joinUrl(base, route)));
    };

    // ---- GitHub：commits / releases / issues ----
    if (isHost(host, 'github.com') && segments.length >= 2) {
      const owner: string = segments[0];
      let repo: string = segments[1];
      if (repo.endsWith('.git')) {
        repo = repo.substring(0, repo.length - 4);
      }
      if (GITHUB_RESERVED.indexOf(owner.toLowerCase()) < 0 && safeSegment(owner) && safeSegment(repo)) {
        add(RssHubKind.GITHUB_COMMITS, '/github/commits/' + owner + '/' + repo);
        add(RssHubKind.GITHUB_RELEASES, '/github/releases/' + owner + '/' + repo);
        add(RssHubKind.GITHUB_ISSUES, '/github/issue/' + owner + '/' + repo);
      }
    }

    // ---- Bilibili：视频 / UP 主 ----
    if (isHost(host, 'bilibili.com')) {
      let uid: string = '';
      if (host.startsWith('space.') && segments.length >= 1) {
        uid = segments[0];
      } else if (segments.length >= 2 && segments[0] === 'space') {
        uid = segments[1];
      }
      if (uid.length > 0 && /^[0-9]+$/.test(uid)) {
        add(RssHubKind.BILIBILI_USER, '/bilibili/user/video/' + uid);
      }
      if (segments.length >= 2 && segments[0] === 'video') {
        const bvid: string = segments[1];
        if (/^BV[0-9A-Za-z]+$/.test(bvid)) {
          add(RssHubKind.BILIBILI_VIDEO, '/bilibili/video/' + bvid);
        }
      }
    }

    // ---- YouTube：频道 / 用户 ----
    if (isHost(host, 'youtube.com')) {
      if (segments.length >= 2 && segments[0] === 'channel' && safeSegment(segments[1])) {
        add(RssHubKind.YOUTUBE_CHANNEL, '/youtube/channel/' + segments[1]);
      }
      if (segments.length >= 1 && segments[0].startsWith('@')) {
        const handle: string = segments[0].substring(1);
        if (safeSegment(handle)) {
          add(RssHubKind.YOUTUBE_USER, '/youtube/user/' + handle);
        }
      }
      if (segments.length >= 2 && (segments[0] === 'user' || segments[0] === 'c')
        && safeSegment(segments[1])) {
        add(RssHubKind.YOUTUBE_USER, '/youtube/user/' + segments[1]);
      }
      if (segments.length >= 1 && YOUTUBE_RESERVED.indexOf(segments[0].toLowerCase()) < 0
        && !segments[0].startsWith('@')
        && segments[0] !== 'channel' && segments[0] !== 'user' && segments[0] !== 'c'
        && segments[0] !== 'playlist' && segments[0] !== 'embed'
        && safeSegment(segments[0])) {
        // 自定义短链（youtube.com/<name>）：与 /c/<name> 同义。
        add(RssHubKind.YOUTUBE_USER, '/youtube/user/' + segments[0]);
      }
    }

    // ---- Twitter / X ----
    if ((isHost(host, 'twitter.com') || isHost(host, 'x.com')) && segments.length >= 1) {
      const user: string = segments[0];
      if (TWITTER_RESERVED.indexOf(user.toLowerCase()) < 0 && safeSegment(user)) {
        add(RssHubKind.TWITTER_USER, '/twitter/user/' + user);
      }
    }

    // ---- 微博 ----
    if (isHost(host, 'weibo.com') || isHost(host, 'weibo.cn')) {
      let uid: string = '';
      if (segments.length >= 2 && segments[0] === 'u') {
        uid = segments[1];
      } else if (segments.length >= 1 && /^[0-9]+$/.test(segments[0])) {
        uid = segments[0];
      }
      if (/^[0-9]+$/.test(uid)) {
        add(RssHubKind.WEIBO_USER, '/weibo/user/' + uid);
      }
    }

    // ---- 知乎 / 简书 / Medium ----
    if (isHost(host, 'zhihu.com') && segments.length >= 2 && segments[0] === 'people'
      && safeSegment(segments[1])) {
      add(RssHubKind.ZHIHU_USER, '/zhihu/people/activities/' + segments[1]);
    }
    if (isHost(host, 'jianshu.com') && segments.length >= 2 && segments[0] === 'u'
      && safeSegment(segments[1])) {
      add(RssHubKind.JIANSHU_USER, '/jianshu/user/' + segments[1]);
    }
    if (isHost(host, 'medium.com') && segments.length >= 1 && segments[0].startsWith('@')
      && safeSegment(segments[0])) {
      add(RssHubKind.MEDIUM_USER, '/medium/' + segments[0]);
    }

    // ---- Instagram / 抖音 ----
    if (isHost(host, 'instagram.com') && segments.length >= 1) {
      const user: string = segments[0];
      const reserved: boolean = user === 'p' || user === 'reel' || user === 'reels'
        || user === 'tv' || user === 'explore' || user === 'accounts';
      if (!reserved && safeSegment(user)) {
        add(RssHubKind.INSTAGRAM_USER, '/instagram/user/' + user);
      }
    }
    if (isHost(host, 'douyin.com') && segments.length >= 2 && segments[0] === 'user'
      && safeSegment(segments[1])) {
      add(RssHubKind.DOUYIN_USER, '/douyin/user/' + segments[1]);
    }

    return suggestions;
  }
}
