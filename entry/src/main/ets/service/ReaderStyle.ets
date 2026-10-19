/*
 * ReaderStyle.ets — 把阅读排版（字号 / 行距）注入到已加载的网页里。
 *
 * 网页原文无法用 ArkUI 的样式控制，只能在 onPageEnd 后用 runJavaScript 插一个 <style> 覆盖
 * 常见文本容器；同时把图片限制在容器宽度内，避免正文溢出。
 * 注入失败只记日志，不影响阅读（页面照常显示，只是沿用站点自身排版）。
 */

import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appSettings } from '../model/AppSettings';
import { safeArea } from './SafeAreaController';
import { ReaderTypography } from '../common/constants/SettingsConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'ReaderStyle';
const STYLE_ID: string = 'hr-reader-style';

export class ReaderStyle {
  /**
   * 依据当前设置生成 CSS（正文字号 / 行距 / 图片自适应 + 浮层让位内边距）。
   *
   * 网页原文无法像 Reader 文档那样自己排版，只能在 onPageEnd 后注入覆盖样式；
   * 正文是铺满整页、从标题栏与悬浮底栏下方穿过的，所以这里给 body 补首尾内边距，
   * 否则首屏文字会被透明标题栏压住、文末文字会被底栏挡住。
   */
  buildCss(): string {
    const size: number = ReaderTypography.fontSize(appSettings.readerFont);
    const line: number = ReaderTypography.lineHeight(appSettings.readerLine);
    return 'body,p,li,div,span,article,section{font-size:' + size + 'px !important;line-height:' + line +
      ' !important;}img,video,table{max-width:100% !important;height:auto !important;}' +
      'body{-webkit-text-size-adjust:100% !important;word-wrap:break-word !important;' +
      'padding-top:' + safeArea.contentTopInsetVp + 'px !important;' +
      'padding-bottom:' + safeArea.contentBottomInsetVp + 'px !important;}';
  }

  /** 注入（幂等：重复调用只更新同一条 style 的内容）。 */
  apply(controller: webview.WebviewController): void {
    const escapedCss: string = JSON.stringify(this.buildCss());
    const script: string = '(function(){var d=document;var s=d.getElementById("' + STYLE_ID + '");' +
      'if(!s){s=d.createElement("style");s.id="' + STYLE_ID + '";(d.head||d.documentElement).appendChild(s);}' +
      's.textContent=' + escapedCss + ';})()';
    controller.runJavaScript(script).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'inject failed: %{public}d', err.code);
    });
  }
}

/** 全局唯一实例。 */
export const readerStyle: ReaderStyle = new ReaderStyle();
