/*
 * ReaderSpeech.ets — 正文朗读（CoreSpeechKit 的 textToSpeech 容错封装）。
 *
 * 只在设备支持时可用：createEngine 失败（缺 Kit / 设备不支持 / 语言包缺失）一律返回 false，
 * 由界面提示「本机不支持朗读」，不抛异常。
 * 引擎按需创建、页面销毁时释放；再次朗读会先停掉上一条。
 */

import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'ReaderSpeech';

/** 朗读语言（中文正文；英文内容也按中文引擎读，后续可按正文语言切换）。 */
const SPEAK_LANGUAGE: string = 'zh-CN';
/** 音色与在线模式：0 分别表示默认音色、离线合成。 */
const SPEAK_PERSON: number = 0;
const SPEAK_ONLINE: number = 0;
/** 单次朗读的文本上限（字符）：超长先截断，避免引擎侧失败。 */
const SPEAK_MAX_CHARS: number = 5000;

export class ReaderSpeech {
  private engine: textToSpeech.TextToSpeechEngine | undefined = undefined;
  private speaking: boolean = false;
  private onState: (speaking: boolean) => void = () => {};

  isSpeaking(): boolean {
    return this.speaking;
  }

  /**
   * 开始朗读；返回 false 表示本机不支持或启动失败（调用方负责提示）。
   * onState 会在开始 / 结束（正常读完、被停止、出错）时回调。
   */
  async start(text: string, onState: (speaking: boolean) => void): Promise<boolean> {
    const body: string = text.length > SPEAK_MAX_CHARS ? text.substring(0, SPEAK_MAX_CHARS) : text;
    if (body.length === 0) {
      return false;
    }
    this.onState = onState;
    try {
      const engine: textToSpeech.TextToSpeechEngine | undefined = await this.ensureEngine();
      if (engine === undefined) {
        return false;
      }
      if (engine.isBusy()) {
        engine.stop();
      }
      this.updateState(true);
      const params: textToSpeech.SpeakParams = { requestId: this.newRequestId() };
      engine.speak(body, params);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'speak failed: %{public}d', error.code);
      this.updateState(false);
      return false;
    }
  }

  /** 停止朗读（幂等）。 */
  stop(): void {
    const engine: textToSpeech.TextToSpeechEngine | undefined = this.engine;
    if (engine !== undefined) {
      try {
        engine.stop();
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'stop failed: %{public}d', error.code);
      }
    }
    this.updateState(false);
  }

  /** 释放引擎（页面销毁时调用；下次朗读会重新创建）。 */
  release(): void {
    const engine: textToSpeech.TextToSpeechEngine | undefined = this.engine;
    this.engine = undefined;
    this.speaking = false;
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

  private updateState(speaking: boolean): void {
    if (this.speaking === speaking) {
      return;
    }
    this.speaking = speaking;
    this.onState(speaking);
  }

  private newRequestId(): string {
    return 'hr' + Date.now().toString();
  }

  /** 按需创建引擎；不支持时返回 undefined（不抛）。 */
  private async ensureEngine(): Promise<textToSpeech.TextToSpeechEngine | undefined> {
    const cached: textToSpeech.TextToSpeechEngine | undefined = this.engine;
    if (cached !== undefined) {
      return cached;
    }
    try {
      const params: textToSpeech.CreateEngineParams = {
        language: SPEAK_LANGUAGE,
        person: SPEAK_PERSON,
        online: SPEAK_ONLINE
      };
      const engine: textToSpeech.TextToSpeechEngine = await textToSpeech.createEngine(params);
      engine.setListener({
        onStart: (requestId: string, response: textToSpeech.StartResponse): void => {
          this.updateState(true);
        },
        onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
          this.updateState(false);
        },
        onStop: (requestId: string, response: textToSpeech.StopResponse): void => {
          this.updateState(false);
        },
        onError: (requestId: string, errorCode: number, errorMessage: string): void => {
          hilog.warn(DOMAIN, TAG, 'speak error: %{public}d', errorCode);
          this.updateState(false);
        }
      });
      this.engine = engine;
      return engine;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'createEngine failed: %{public}d', error.code);
      return undefined;
    }
  }
}

/** 全局唯一实例（同一时刻只朗读一篇）。 */
export const readerSpeech: ReaderSpeech = new ReaderSpeech();
