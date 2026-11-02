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
   * 依据当前设置生成 CSS（正文字号 / 行距 / 图片自适应 + 顶部 / 底部浮层让位内边距）。
   *
   * 网页原文无法像 Reader 文档那样自己排版，只能在 onPageEnd 后注入覆盖样式。
   * 顶部让位（topPad = 状态栏 + 标题栏的高）写在 body 的 padding-top 上：让位跟着内容走，
   * 首行被推到标题栏下沿之外，滚动时正文继续从状态栏 / 标题栏下方穿过。
   * 底部也要补，否则文末文字会被悬浮操作栏挡住。
   */
  buildCss(topPad: number = 0): string {
    const size: number = ReaderTypography.fontSizePx(appSettings.readerFontScale);
    const line: number = size * ReaderTypography.lineHeightOf(appSettings.readerLineScale);
    // 网页原文模式只能覆盖文本容器：字号 / 行距 / 字体族 + 图片自适应 + 浮层让位内边距。
    // 栏宽 / 对齐 / 主题受站点布局限制，不在这里强行注入（面板里会说明）。
    const family: string = ReaderTypography.fontFamilyCss(appSettings.readerFontFamily);
    const familyRule: string = family.length > 0
      ? 'font-family:' + family + ' !important;'
      : '';
    const topRule: string = topPad > 0
      ? 'padding-top:' + topPad + 'px !important;'
      : '';
    // 只覆盖可识别的正文容器，避免把站点导航、按钮、卡片和媒体控件一起放大。
    const content: string = 'article,main,.entry-content,.post-content,.article-content,.post-body,.prose';
    return ':where(' + content + '){font-size:' + size + 'px !important;line-height:' + line +
      'px !important;' + familyRule + '}' +
      ':where(' + content + ') :where(p,li,blockquote){font-size:inherit !important;line-height:inherit !important;}' +
      ':where(' + content + ') :where(img,video,table){max-width:100% !important;height:auto !important;}' +
      'body{-webkit-text-size-adjust:100% !important;word-wrap:break-word !important;' +
      topRule +
      'padding-bottom:' + safeArea.contentBottomInsetVp + 'px !important;}';
  }

  /** 注入（幂等：重复调用只更新同一条 style 的内容）。 */
  apply(controller: webview.WebviewController, topPad: number = 0): void {
    const escapedCss: string = JSON.stringify(this.buildCss(topPad));
    const script: string = '(function(){var d=document;var s=d.getElementById("' + STYLE_ID + '");' +
      'if(!s){s=d.createElement("style");s.id="' + STYLE_ID + '";(d.head||d.documentElement).appendChild(s);}' +
      's.textContent=' + escapedCss + ';})()';
    try {
      controller.runJavaScript(script).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'inject failed: %{public}d', err.code);
      });
    } catch (err) {
      // 页面尺寸回调可能早于 Web 挂载，此时 runJavaScript 会同步抛错；onPageEnd 会再次注入。
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'inject before attach failed: %{public}d', error.code);
    }
  }
}

/** 全局唯一实例。 */
export const readerStyle: ReaderStyle = new ReaderStyle();
