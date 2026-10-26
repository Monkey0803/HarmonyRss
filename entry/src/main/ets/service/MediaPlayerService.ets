/*
 * MediaPlayerService.ets — 播客音频播放（AVPlayer + AVSession + 后台长时任务）。
 *
 * 能力：
 *   - 队列播放（按源 / 全部未听，由上层查库后传入）；
 *   - 播放 / 暂停、±15s、倍速、上一首 / 下一首、进度记忆；
 *   - AVSession：锁屏 / 媒体中心控制与元数据；
 *   - 后台长时任务：AUDIO_PLAYBACK（需要 KEEP_BACKGROUND_RUNNING 权限与 backgroundModes）；
 *   - 与正文朗读互斥：开始播放音频时先停掉 ReaderSpeech。
 *
 * 失败处理：任何平台异常只记日志并把状态置为 error，不影响阅读与其它功能。
 */

import { media } from '@kit.MediaKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Article } from '../model/Feed';
import { Enclosure, firstAudio } from '../model/Enclosure';
import { articleStore } from './ArticleStore';
import { readerSpeech } from './ReaderSpeech';

const DOMAIN: number = 0x0000;
const TAG: string = 'MediaPlayerService';
const MAIN_ABILITY: string = 'EntryAbility';
const SESSION_TAG: string = 'HarmonyRssReader';
/** 后端任务 requestCode（与通知 / 卡片区分）。 */
const BACKGROUND_REQUEST_CODE: number = 3001;
/** 倍速档位（与 AVPlayer.PlaybackSpeed 一一对应）。 */
const SPEEDS: number[] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
/** 进度写库节流（秒）。 */
const SAVE_INTERVAL_SECONDS: number = 5;

/** 播放状态。 */
export const MEDIA_IDLE: string = 'idle';
export const MEDIA_LOADING: string = 'loading';
export const MEDIA_PLAYING: string = 'playing';
export const MEDIA_PAUSED: string = 'paused';
export const MEDIA_ERROR: string = 'error';

/** 队列中的一条音频。 */
export class MediaTrack {
  readonly articleId: string;
  readonly title: string;
  readonly feedTitle: string;
  readonly url: string;
  readonly duration: number;
  readonly imageUrl: string;

  constructor(articleId: string, title: string, feedTitle: string, url: string, duration: number,
    imageUrl: string) {
    this.articleId = articleId;
    this.title = title;
    this.feedTitle = feedTitle;
    this.url = url;
    this.duration = duration;
    this.imageUrl = imageUrl;
  }
}

/** 从文章构造音频队列项；没有音频返回 undefined。 */
export function trackOf(article: Article): MediaTrack | undefined {
  const audio: Enclosure | undefined = firstAudio(article.enclosures);
  if (audio === undefined) {
    return undefined;
  }
  return new MediaTrack(article.id, article.title, article.feedTitle, audio.url,
    enclosureDuration(article), article.imageUrl);
}

/** 取文章音频时长（秒）；没有音频返回 0。 */
function enclosureDuration(article: Article): number {
  const audio: Enclosure | undefined = firstAudio(article.enclosures);
  return audio !== undefined ? audio.duration : 0;
}

/** 倍速 → AVPlayer 枚举。 */
function playbackSpeedOf(speed: number): media.PlaybackSpeed {
  if (speed === 0.75) {
    return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
  }
  if (speed === 1.25) {
    return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
  }
  if (speed === 1.5) {
    return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
  }
  if (speed === 1.75) {
    return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
  }
  if (speed === 2.0) {
    return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
  }
  return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
}

@ObservedV2
export class MediaPlayerService {
  /** idle / loading / playing / paused / error。 */
  @Trace status: string = MEDIA_IDLE;
  @Trace title: string = '';
  @Trace feedTitle: string = '';
  @Trace articleId: string = '';
  @Trace coverUrl: string = '';
  /** 已播放秒数（向上取整用于展示）。 */
  @Trace positionSeconds: number = 0;
  @Trace durationSeconds: number = 0;
  @Trace speed: number = 1.0;
  @Trace queueIndex: number = 0;
  @Trace queueSize: number = 0;

  private player: media.AVPlayer | undefined = undefined;
  private session: avSession.AVSession | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;
  private queue: MediaTrack[] = [];
  private current: MediaTrack | undefined = undefined;
  private lastSavedSecond: number = -1;
  private backgroundRunning: boolean = false;
  private switching: boolean = false;

  /** 当前是否有可展示的播放器（含暂停 / 出错）。 */
  hasTrack(): boolean {
    return this.current !== undefined && this.status !== MEDIA_IDLE;
  }

  isPlaying(): boolean {
    return this.status === MEDIA_PLAYING;
  }

  currentUrl(): string {
    return this.current !== undefined ? this.current.url : '';
  }

  /**
   * 播放一个队列。
   * @param startArticleId 从哪一篇开始；空串 / 不在队列里时从头开始。
   */
  async playQueue(context: common.UIAbilityContext, articles: Article[], startArticleId: string): Promise<boolean> {
    const tracks: MediaTrack[] = [];
    for (let i = 0; i < articles.length; i += 1) {
      const track: MediaTrack | undefined = trackOf(articles[i]);
      if (track !== undefined) {
        tracks.push(track);
      }
    }
    if (tracks.length === 0) {
      this.status = MEDIA_ERROR;
      return false;
    }
    this.context = context;
    this.queue = tracks;
    this.queueSize = tracks.length;
    let index: number = 0;
    for (let i = 0; i < tracks.length; i += 1) {
      if (tracks[i].articleId === startArticleId) {
        index = i;
        break;
      }
    }
    // 用户从当前文章点播放时，即使它不在「未听」队列里也放在第一位。
    if (startArticleId.length > 0 && tracks[index].articleId !== startArticleId) {
      for (let i = 0; i < articles.length; i += 1) {
        if (articles[i].id === startArticleId) {
          const currentTrack: MediaTrack | undefined = trackOf(articles[i]);
          if (currentTrack !== undefined) {
            tracks.unshift(currentTrack);
            index = 0;
            this.queueSize = tracks.length;
          }
          break;
        }
      }
    }
    this.queueIndex = index;
    return await this.loadTrack(index);
  }

  /** 播放 / 暂停切换。 */
  async toggle(): Promise<void> {
    if (this.status === MEDIA_PLAYING) {
      await this.pause();
      return;
    }
    if (this.status === MEDIA_PAUSED || this.status === MEDIA_ERROR) {
      await this.resume();
    }
  }

  /** 暂停并保存进度；同时结束后台长时任务。 */
  async pause(): Promise<void> {
    const player: media.AVPlayer | undefined = this.player;
    if (player === undefined) {
      return;
    }
    try {
      await player.pause();
    } catch (err) {
      this.logError('pause', err);
    }
    this.status = MEDIA_PAUSED;
    await this.saveProgress();
    await this.stopBackground();
    await this.updateSessionState();
  }

  /** 继续播放；必要时重新申请后台长时任务。 */
  async resume(): Promise<void> {
    const player: media.AVPlayer | undefined = this.player;
    if (player === undefined) {
      if (this.queue.length > 0) {
        await this.loadTrack(this.queueIndex);
      }
      return;
    }
    try {
      // 播完后再点继续：先回到开头，否则部分实现会停在 completed 状态不出声。
      if (this.durationSeconds > 0 && this.positionSeconds >= this.durationSeconds - 1) {
        player.seek(0);
        this.positionSeconds = 0;
      }
      await player.play();
      this.status = MEDIA_PLAYING;
      await this.startBackground();
      await this.updateSessionState();
    } catch (err) {
      this.logError('resume', err);
      this.status = MEDIA_ERROR;
    }
  }

  /** 相对当前位置快进 / 快退（秒）。 */
  seekBy(seconds: number): void {
    const player: media.AVPlayer | undefined = this.player;
    if (player === undefined) {
      return;
    }
    const target: number = Math.max(0, this.positionSeconds + seconds);
    const max: number = this.durationSeconds > 0 ? this.durationSeconds : target;
    this.seekTo(Math.min(target, max));
  }

  /** 绝对定位（秒）。 */
  seekTo(seconds: number): void {
    const player: media.AVPlayer | undefined = this.player;
    if (player === undefined) {
      return;
    }
    const value: number = Number.isFinite(seconds) && seconds > 0 ? seconds : 0;
    this.positionSeconds = value;
    try {
      player.seek(Math.floor(value * 1000));
      this.updateSessionState();
    } catch (err) {
      this.logError('seek', err);
    }
  }

  /** 切换倍速（循环）。 */
  cycleSpeed(): number {
    const index: number = SPEEDS.indexOf(this.speed);
    const next: number = SPEEDS[(index + 1) % SPEEDS.length];
    this.speed = next;
    const player: media.AVPlayer | undefined = this.player;
    if (player !== undefined) {
      try {
        player.setSpeed(playbackSpeedOf(next));
      } catch (err) {
        this.logError('setSpeed', err);
      }
    }
    this.updateSessionState();
    return next;
  }

  /** 下一首。 */
  async next(): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    const nextIndex: number = (this.queueIndex + 1) % this.queue.length;
    await this.loadTrack(nextIndex);
  }

  /** 上一首。 */
  async prev(): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    const prevIndex: number = (this.queueIndex - 1 + this.queue.length) % this.queue.length;
    await this.loadTrack(prevIndex);
  }

  /** 停止并释放（离开详情页 / 用户点停止）。 */
  async stop(): Promise<void> {
    await this.saveProgress();
    const player: media.AVPlayer | undefined = this.player;
    this.player = undefined;
    if (player !== undefined) {
      try {
        await player.stop();
      } catch (err) {
        // 尚未 prepared 时 stop 可能失败，忽略。
      }
      try {
        await player.release();
      } catch (err) {
        this.logError('release', err);
      }
    }
    await this.stopBackground();
    const session: avSession.AVSession | undefined = this.session;
    this.session = undefined;
    if (session !== undefined) {
      try {
        await session.destroy();
      } catch (err) {
        this.logError('destroy session', err);
      }
    }
    this.current = undefined;
    this.queue = [];
    this.queueIndex = 0;
    this.queueSize = 0;
    this.status = MEDIA_IDLE;
    this.positionSeconds = 0;
    this.durationSeconds = 0;
    this.title = '';
    this.feedTitle = '';
    this.articleId = '';
    this.coverUrl = '';
  }

  /** 打开外部视频（系统播放器 / 浏览器兜底）。 */
  async openVideo(context: common.UIAbilityContext, enclosure: Enclosure): Promise<boolean> {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: enclosure.url,
      type: enclosure.type.length > 0 ? enclosure.type : 'video/*'
    };
    try {
      await context.startAbility(want);
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'open video failed, fallback to browser: %{public}s', this.messageOf(err));
      return false;
    }
  }

  /** 加载队列中的某一首。 */
  private async loadTrack(index: number): Promise<boolean> {
    if (index < 0 || index >= this.queue.length || this.switching) {
      return false;
    }
    this.switching = true;
    try {
      await this.saveProgress();
      await this.releasePlayer();
      const track: MediaTrack = this.queue[index];
      this.current = track;
      this.queueIndex = index;
      this.title = track.title;
      this.feedTitle = track.feedTitle;
      this.articleId = track.articleId;
      this.coverUrl = track.imageUrl;
      this.positionSeconds = 0;
      this.durationSeconds = track.duration;
      this.lastSavedSecond = -1;
      this.status = MEDIA_LOADING;
      // 与 TTS 互斥：音频开始前停掉正文朗读。
      readerSpeech.stop();
      const player: media.AVPlayer = await media.createAVPlayer();
      this.player = player;
      this.bindPlayer(player);
      player.url = track.url;
      await player.prepare();
      player.setSpeed(playbackSpeedOf(this.speed));
      const saved: number = await this.loadProgress(track.articleId);
      if (saved > 0 && saved < (this.durationSeconds > 0 ? this.durationSeconds - 5 : saved + 1)) {
        this.positionSeconds = saved;
        player.seek(saved * 1000);
      }
      await this.ensureSession();
      await this.updateSessionMetadata();
      await player.play();
      this.status = MEDIA_PLAYING;
      await this.startBackground();
      await this.updateSessionState();
      return true;
    } catch (err) {
      this.logError('loadTrack', err);
      this.status = MEDIA_ERROR;
      return false;
    } finally {
      this.switching = false;
    }
  }

  /** 绑定 AVPlayer 的事件。 */
  private bindPlayer(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason) => {
      if (state === 'playing') {
        this.status = MEDIA_PLAYING;
      } else if (state === 'paused') {
        this.status = MEDIA_PAUSED;
      } else if (state === 'completed') {
        this.status = MEDIA_PAUSED;
        // 播完记为「已听」：下次「全部未听」队列不再包含它。
        this.positionSeconds = this.durationSeconds > 0 ? this.durationSeconds : this.positionSeconds;
        this.saveProgress();
        this.stopBackground();
        this.updateSessionState();
        // 自动下一首：队列只有一首时停留在当前（不循环轰炸）。
        if (this.queue.length > 1) {
          this.next().catch(() => {
          });
        }
      }
    });
    player.on('timeUpdate', (time: number) => {
      const seconds: number = Math.max(0, Math.floor(time / 1000));
      this.positionSeconds = seconds;
      if (seconds > this.durationSeconds) {
        this.durationSeconds = seconds;
      }
      if (seconds - this.lastSavedSecond >= SAVE_INTERVAL_SECONDS) {
        this.lastSavedSecond = seconds;
        this.saveProgress();
      }
    });
    player.on('durationUpdate', (duration: number) => {
      const seconds: number = Math.max(0, Math.floor(duration / 1000));
      if (seconds > 0) {
        this.durationSeconds = seconds;
        this.updateSessionState();
      }
    });
    player.on('error', (err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'player error: %{public}d %{public}s', err.code,
        err.message !== undefined ? err.message : '');
      this.status = MEDIA_ERROR;
    });
  }

  /** 读上次播放位置（秒）。 */
  private async loadProgress(articleId: string): Promise<number> {
    const article: Article | undefined = await articleStore.loadById(articleId);
    return article !== undefined ? article.mediaProgress : 0;
  }

  /** 写播放位置（秒）。 */
  private async saveProgress(): Promise<void> {
    const track: MediaTrack | undefined = this.current;
    if (track === undefined) {
      return;
    }
    await articleStore.setMediaProgress(track.articleId, this.positionSeconds);
  }

  /** 释放 AVPlayer（切歌用，会话保留）。 */
  private async releasePlayer(): Promise<void> {
    const player: media.AVPlayer | undefined = this.player;
    this.player = undefined;
    if (player === undefined) {
      return;
    }
    try {
      await player.stop();
    } catch (err) {
      // 未 prepared 时忽略。
    }
    try {
      await player.release();
    } catch (err) {
      this.logError('release player', err);
    }
  }

  /** 创建 / 复用 AVSession，并注册锁屏 / 媒体中心控制。 */
  private async ensureSession(): Promise<void> {
    if (this.session !== undefined) {
      await this.session.activate();
      return;
    }
    const context: common.UIAbilityContext | undefined = this.context;
    if (context === undefined) {
      return;
    }
    try {
      const session: avSession.AVSession = await avSession.createAVSession(context, SESSION_TAG, 'audio');
      this.session = session;
      session.on('play', () => {
        this.resume().catch(() => {
        });
      });
      session.on('pause', () => {
        this.pause().catch(() => {
        });
      });
      session.on('playNext', () => {
        this.next().catch(() => {
        });
      });
      session.on('playPrevious', () => {
        this.prev().catch(() => {
        });
      });
      session.on('seek', (time: number) => {
        this.seekTo(Math.floor(time / 1000));
      });
      await session.activate();
    } catch (err) {
      this.logError('ensure session', err);
    }
  }

  /** 更新锁屏元数据。 */
  private async updateSessionMetadata(): Promise<void> {
    const session: avSession.AVSession | undefined = this.session;
    const track: MediaTrack | undefined = this.current;
    if (session === undefined || track === undefined) {
      return;
    }
    const metadata: avSession.AVMetadata = {
      assetId: track.articleId,
      title: track.title,
      artist: track.feedTitle,
      duration: this.durationSeconds > 0 ? this.durationSeconds * 1000 : 0
    };
    if (track.imageUrl.length > 0) {
      metadata.mediaImage = track.imageUrl;
    }
    if (this.queueIndex > 0) {
      metadata.previousAssetId = this.queue[this.queueIndex - 1].articleId;
    }
    if (this.queueIndex + 1 < this.queue.length) {
      metadata.nextAssetId = this.queue[this.queueIndex + 1].articleId;
    }
    try {
      await session.setAVMetadata(metadata);
    } catch (err) {
      this.logError('set metadata', err);
    }
  }

  /** 同步锁屏播放状态。 */
  private async updateSessionState(): Promise<void> {
    const session: avSession.AVSession | undefined = this.session;
    if (session === undefined) {
      return;
    }
    const state: avSession.AVPlaybackState = {
      state: this.status === MEDIA_PLAYING
        ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : (this.status === MEDIA_LOADING
          ? avSession.PlaybackState.PLAYBACK_STATE_PREPARE
          : avSession.PlaybackState.PLAYBACK_STATE_PAUSE),
      speed: this.speed,
      position: {
        elapsedTime: this.positionSeconds * 1000,
        updateTime: Date.now()
      },
      duration: this.durationSeconds * 1000
    };
    try {
      await session.setAVPlaybackState(state);
    } catch (err) {
      this.logError('set playback state', err);
    }
  }

  /** 申请后台长时任务（AVSession 已接入，系统不会额外弹通知）。 */
  private async startBackground(): Promise<void> {
    const context: common.UIAbilityContext | undefined = this.context;
    if (context === undefined || this.backgroundRunning) {
      return;
    }
    try {
      const agent: WantAgent | undefined = await this.buildWantAgent(context);
      if (agent === undefined) {
        return;
      }
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.backgroundRunning = true;
    } catch (err) {
      this.logError('start background', err);
    }
  }

  /** 结束后台长时任务。 */
  private async stopBackground(): Promise<void> {
    const context: common.UIAbilityContext | undefined = this.context;
    if (context === undefined || !this.backgroundRunning) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (err) {
      this.logError('stop background', err);
    }
    this.backgroundRunning = false;
  }

  /** 后台任务点回应用用的 WantAgent。 */
  private async buildWantAgent(context: common.UIAbilityContext): Promise<WantAgent | undefined> {
    try {
      const want: Want = {
        bundleName: context.applicationInfo.name,
        abilityName: MAIN_ABILITY
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: BACKGROUND_REQUEST_CODE,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      return await wantAgent.getWantAgent(info);
    } catch (err) {
      this.logError('want agent', err);
      return undefined;
    }
  }

  private logError(action: string, err: Object): void {
    const error: BusinessError = err as BusinessError;
    hilog.warn(DOMAIN, TAG, '%{public}s failed: %{public}d %{public}s', action,
      typeof error.code === 'number' ? error.code : 0,
      error.message !== undefined ? error.message : '');
  }

  private messageOf(err: Object): string {
    const error: Error = err as Error;
    return error.message !== undefined ? error.message : 'unknown';
  }
}

/** 全局唯一实例。 */
export const mediaPlayerService: MediaPlayerService = new MediaPlayerService();
