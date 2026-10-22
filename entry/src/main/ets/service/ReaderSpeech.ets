/*
 * ReaderSpeech.ets — 正文朗读（CoreSpeechKit 的 textToSpeech 容错封装）。
 *
 * 能力：
 *   - 长文分句：按句末标点切块，逐块送入引擎，onComplete 后续读下一块，不再有 5000 字截断；
 *   - 暂停 / 继续：引擎没有 pause，暂停即 stop 并把断点留在当前块，继续时从该块开头重读；
 *   - 倍速：通过 SpeakParams.extraParams 的 speed 生效，切换后从当前块重新播报；
 *   - 容错：createEngine 失败（缺 Kit / 设备不支持 / 语言包缺失）一律返回 false，由界面提示。
 *
 * 引擎按需创建、页面销毁时释放；再次朗读会先停掉上一条。
 */

import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ReaderSpeech';

/** 朗读语言（中文正文；英文内容也按中文引擎读，后续可按正文语言切换）。 */
const SPEAK_LANGUAGE: string = 'zh-CN';
/** 音色：0 / 13 均为聆小珊女声。 */
const SPEAK_PERSON: number = 0;
/** 模式：0 = 在线（当前不支持），1 = 离线（本机合成）。 */
const SPEAK_ONLINE_OFFLINE: number = 1;
/** 每个分句块的目标长度（字符）与回退查找分隔符的下限。 */
const SPEAK_CHUNK_CHARS: number = 160;
const SPEAK_CHUNK_MIN: number = 60;
/** 句末标点：逐块朗读的切分点。 */
const SENTENCE_MARKS: string = '。！？!?；;…\n';
/** 块内换行 / 空白归一。 */
const SPACE_PATTERN: RegExp = /\s+/g;

/** 可切换的语速（引擎 speed 参数，1.0 为正常）。 */
export const SPEECH_SPEEDS: number[] = [0.8, 1.0, 1.3, 1.6, 2.0];
const DEFAULT_SPEED_INDEX: number = 1;

export enum SpeechStatus {
  IDLE = 0,
  SPEAKING = 1,
  PAUSED = 2
}

/** 朗读进度快照：界面据此渲染播放条。 */
export class SpeechProgress {
  status: SpeechStatus = SpeechStatus.IDLE;
  /** 当前读到第几块（0 基）。 */
  index: number = 0;
  /** 正文一共切了多少块。 */
  total: number = 0;
  speed: number = 1;
}

/** 把正文切成适合逐块朗读的句子块（保序、不丢字符）。 */
function splitIntoChunks(text: string): string[] {
  const normalized: string = text.replace(SPACE_PATTERN, ' ').trim();
  const chunks: string[] = [];
  let buffer: string = '';
  for (let i = 0; i < normalized.length; i++) {
    const ch: string = normalized.charAt(i);
    buffer += ch;
    if (SENTENCE_MARKS.indexOf(ch) >= 0) {
      pushChunk(chunks, buffer);
      buffer = '';
      continue;
    }
    if (buffer.length < SPEAK_CHUNK_CHARS) {
      continue;
    }
    // 超长句：在末尾附近回退到逗号 / 空格，避免把词截断。
    let cut: number = -1;
    for (let j = buffer.length - 1; j >= SPEAK_CHUNK_MIN; j--) {
      const c: string = buffer.charAt(j);
      if (c === '，' || c === ',' || c === '、' || c === '：' || c === ':' || c === ' ') {
        cut = j;
        break;
      }
    }
    if (cut > 0) {
      pushChunk(chunks, buffer.substring(0, cut + 1));
      buffer = buffer.substring(cut + 1);
    } else {
      pushChunk(chunks, buffer);
      buffer = '';
    }
  }
  pushChunk(chunks, buffer);
  return chunks;
}

function pushChunk(chunks: string[], value: string): void {
  const trimmed: string = value.trim();
  if (trimmed.length > 0) {
    chunks.push(trimmed);
  }
}

export class ReaderSpeech {
  private engine: textToSpeech.TextToSpeechEngine | undefined = undefined;
  private status: SpeechStatus = SpeechStatus.IDLE;
  private chunks: string[] = [];
  private index: number = 0;
  private speed: number = SPEECH_SPEEDS[DEFAULT_SPEED_INDEX];
  private currentId: string = '';
  private seq: number = 0;
  private retries: number = 0;
  /** 扩展参数被引擎拒绝后，降级为最小参数重试一次。 */
  private plainParams: boolean = false;
  private onProgress: (progress: SpeechProgress) => void = () => {};

  isSpeaking(): boolean {
    return this.status !== SpeechStatus.IDLE;
  }

  isPaused(): boolean {
    return this.status === SpeechStatus.PAUSED;
  }

  currentSpeed(): number {
    return this.speed;
  }

  /**
   * 开始朗读；返回 false 表示本机不支持或启动失败（调用方负责提示）。
   * onProgress 在开始 / 换块 / 暂停 / 继续 / 结束 / 出错时回调。
   */
  async start(text: string, onProgress: (progress: SpeechProgress) => void): Promise<boolean> {
    const chunks: string[] = splitIntoChunks(text);
    if (chunks.length === 0) {
      return false;
    }
    this.onProgress = onProgress;
    this.chunks = chunks;
    this.index = 0;
    this.retries = 0;
    this.plainParams = false;
    this.status = SpeechStatus.SPEAKING;
    this.currentId = '';
    try {
      const engine: textToSpeech.TextToSpeechEngine | undefined = await this.ensureEngine();
      if (engine === undefined) {
        this.reset();
        return false;
      }
      this.emit();
      // 上一条可能还在收尾：先停掉，稍等引擎空闲再送第一块。
      if (engine.isBusy()) {
        engine.stop();
        setTimeout(() => {
          this.speakCurrent();
        }, 120);
      } else {
        this.speakCurrent();
      }
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'speak failed: %{public}d', error.code);
      this.reset();
      return false;
    }
  }

  /** 暂停：停掉当前块，断点留在这一块（继续时从块首重读）。 */
  pause(): void {
    if (this.status !== SpeechStatus.SPEAKING) {
      return;
    }
    this.status = SpeechStatus.PAUSED;
    this.currentId = '';
    this.stopEngine();
    this.emit();
  }

  /** 继续：从暂停时所在块重新开始。 */
  resume(): void {
    if (this.status !== SpeechStatus.PAUSED) {
      return;
    }
    this.status = SpeechStatus.SPEAKING;
    this.retries = 0;
    this.emit();
    // stop 是异步收尾，给引擎一点时间释放，否则容易撞 1002300006（忙碌）。
    setTimeout(() => {
      this.speakCurrent();
    }, 120);
  }

  /** 切换语速；朗读中立即从当前块用新语速重读。 */
  cycleSpeed(): number {
    const index: number = SPEECH_SPEEDS.indexOf(this.speed);
    const next: number = SPEECH_SPEEDS[(index + 1) % SPEECH_SPEEDS.length];
    this.speed = next;
    if (this.status === SpeechStatus.SPEAKING) {
      this.restartCurrent();
    } else {
      this.emit();
    }
    return next;
  }

  /** 停止朗读（幂等）。 */
  stop(): void {
    if (this.status === SpeechStatus.IDLE && this.chunks.length === 0) {
      return;
    }
    this.reset();
    this.emit();
  }

  /** 释放引擎（页面销毁时调用；下次朗读会重新创建）。 */
  release(): void {
    const engine: textToSpeech.TextToSpeechEngine | undefined = this.engine;
    this.engine = undefined;
    this.reset();
    if (engine === undefined) {
      return;
    }
    try {
      engine.shutdown();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'shutdown failed: %{public}d', error.code);
    }
  }

  private restartCurrent(): void {
    this.currentId = '';
    this.stopEngine();
    this.retries = 0;
    this.emit();
    setTimeout(() => {
      this.speakCurrent();
    }, 120);
  }

  private reset(): void {
    this.status = SpeechStatus.IDLE;
    this.chunks = [];
    this.index = 0;
    this.retries = 0;
    this.currentId = '';
  }

  private stopEngine(): void {
    const engine: textToSpeech.TextToSpeechEngine | undefined = this.engine;
    if (engine === undefined) {
      return;
    }
    try {
      engine.stop();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'stop failed: %{public}d', error.code);
    }
  }

  /** 送当前块去合成；若引擎仍忙碌（上一条 stop 未收尾），短暂重试。 */
  private speakCurrent(): void {
    if (this.status !== SpeechStatus.SPEAKING) {
      return;
    }
    const engine: textToSpeech.TextToSpeechEngine | undefined = this.engine;
    if (engine === undefined) {
      return;
    }
    const text: string | undefined = this.chunks[this.index];
    if (text === undefined) {
      this.finish();
      return;
    }
    const requestId: string = this.newRequestId();
    this.currentId = requestId;
    const params: textToSpeech.SpeakParams = { requestId: requestId };
    if (!this.plainParams) {
      const extraParams: Record<string, Object> = {
        'speed': this.speed,
        'isBackStage': true
      };
      params.extraParams = extraParams;
    }
    try {
      engine.speak(text, params);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'speak failed: %{public}d', error.code);
      // 401：扩展参数不被支持，降级为纯 requestId 再试一次。
      if (error.code === 401 && !this.plainParams) {
        this.plainParams = true;
        this.currentId = '';
        setTimeout(() => {
          this.speakCurrent();
        }, 60);
        return;
      }
      this.finish();
    }
  }

  private finish(): void {
    this.reset();
    this.emit();
  }

  private emit(): void {
    const progress: SpeechProgress = new SpeechProgress();
    progress.status = this.status;
    progress.index = this.index;
    progress.total = this.chunks.length;
    progress.speed = this.speed;
    this.onProgress(progress);
  }

  private newRequestId(): string {
    this.seq++;
    return 'hr' + this.seq.toString() + '_' + Date.now().toString();
  }

  /** 按需创建引擎；不支持时返回 undefined（不抛）。 */
  private async ensureEngine(): Promise<textToSpeech.TextToSpeechEngine | undefined> {
    const cached: textToSpeech.TextToSpeechEngine | undefined = this.engine;
    if (cached !== undefined) {
      return cached;
    }
    try {
      const extraParams: Record<string, Object> = {
        'style': 'interaction-broadcast',
        'locate': 'CN',
        'name': 'HarmonyRssReader',
        'isBackStage': true
      };
      const params: textToSpeech.CreateEngineParams = {
        language: SPEAK_LANGUAGE,
        person: SPEAK_PERSON,
        online: SPEAK_ONLINE_OFFLINE,
        extraParams: extraParams
      };
      const engine: textToSpeech.TextToSpeechEngine = await textToSpeech.createEngine(params);
      this.setListener(engine);
      this.engine = engine;
      return engine;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'createEngine failed: %{public}d', error.code);
      // 扩展参数（style / 后台播报）不被支持时，退回最小参数再创建一次。
      try {
        const minimal: textToSpeech.CreateEngineParams = {
          language: SPEAK_LANGUAGE,
          person: SPEAK_PERSON,
          online: SPEAK_ONLINE_OFFLINE
        };
        const engine: textToSpeech.TextToSpeechEngine = await textToSpeech.createEngine(minimal);
        this.setListener(engine);
        this.engine = engine;
        return engine;
      } catch (retryErr) {
        const retryError: BusinessError = retryErr as BusinessError;
        hilog.error(DOMAIN, TAG, 'createEngine retry failed: %{public}d', retryError.code);
        return undefined;
      }
    }
  }

  private setListener(engine: textToSpeech.TextToSpeechEngine): void {
    engine.setListener({
      onStart: (requestId: string, response: textToSpeech.StartResponse): void => {
        if (requestId !== this.currentId) {
          return;
        }
        this.retries = 0;
      },
      onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
        if (requestId !== this.currentId) {
          return;
        }
        if (this.status !== SpeechStatus.SPEAKING) {
          return;
        }
        this.retries = 0;
        this.index++;
        if (this.index >= this.chunks.length) {
          this.finish();
          return;
        }
        this.emit();
        this.speakCurrent();
      },
      onStop: (requestId: string, response: textToSpeech.StopResponse): void => {
        // 主动 stop 时 currentId 已被清空，这里只处理非主动停止（如系统打断）。
        if (requestId !== this.currentId) {
          return;
        }
        if (this.status === SpeechStatus.SPEAKING) {
          this.finish();
        }
      },
      onError: (requestId: string, errorCode: number, errorMessage: string): void => {
        if (requestId !== this.currentId) {
          return;
        }
        // 1002300006：服务忙碌，通常是上一条 stop 尚未收尾，重试即可。
        if (errorCode === 1002300006 && this.retries < 2) {
          this.retries++;
          this.currentId = '';
          setTimeout(() => {
            this.speakCurrent();
          }, 180);
          return;
        }
        // 401：扩展参数（语速 / 后台播报）不被支持，降级重试一次。
        if (errorCode === 401 && !this.plainParams) {
          this.plainParams = true;
          this.currentId = '';
          setTimeout(() => {
            this.speakCurrent();
          }, 60);
          return;
        }
        hilog.warn(DOMAIN, TAG, 'speak error: %{public}d', errorCode);
        this.finish();
      }
    });
  }
}

/** 全局唯一实例（同一时刻只朗读一篇）。 */
export const readerSpeech: ReaderSpeech = new ReaderSpeech();
