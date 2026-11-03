/*
 * WebBodyView.ets — 网页原文的 ArkWeb 容器。
 *
 * 与 ReaderBodyView 同一思路：只渲染「原始链接」并回传 Web 事件，
 * 排版注入、进度恢复、SPA 快照、错误兜底等编排全部留在详情页。
 */

import { webview } from '@kit.ArkWeb';
import { ReaderHighlightBridge } from '../../service/ReaderHighlight';

@ComponentV2
export struct WebBodyView {
  /** 原文地址；为空时详情页不会挂载本组件。 */
  @Param link: string = '';
  @Param controller: webview.WebviewController = new webview.WebviewController();
  @Param highlightBridge: ReaderHighlightBridge = new ReaderHighlightBridge((id: string) => {
  });
  /** 横向滑动切文的触发距离（vp）。 */
  @Param swipeDistance: number = 60;

  @Event onLoadIntercept: (event: OnLoadInterceptEvent) => boolean = () => false;
  @Event onWindowNew: (event: OnWindowNewEvent) => void = (event: OnWindowNewEvent): void => {
    event.handler.setWebController(null);
  };
  @Event onMainFrameError: () => void = () => {
  };
  @Event onSelection: (text: string) => void = () => {
  };
  @Event onTouchEvent: (event: TouchEvent) => void = () => {
  };
  @Event onPageEnd: () => void = () => {
  };
  @Event onOverScroll: (event: OnOverScrollEvent) => void = () => {
  };
  @Event onPanStart: (event: GestureEvent) => void = () => {
  };
  @Event onPanEnd: (event: GestureEvent) => void = () => {
  };

  build() {
    Web({ src: this.link, controller: this.controller })
      .width('100%')
      .height('100%')
      .darkMode(WebDarkMode.Auto)
      .javaScriptAccess(true)
      .domStorageAccess(true)
      // 文档内点标注：window.__hrHlCb.onHlClick(id)
      .javaScriptProxy({
        object: this.highlightBridge,
        name: '__hrHlCb',
        methodList: ['onHlClick'],
        controller: this.controller
      })
      .onLoadIntercept((event: OnLoadInterceptEvent): boolean => {
        return this.onLoadIntercept(event);
      })
      .multiWindowAccess(true)
      .onWindowNew((event: OnWindowNewEvent): void => {
        this.onWindowNew(event);
      })
      // 只有顶层文档失败才展示错误页；子资源失败不遮住可读正文。
      .onErrorReceive((event: OnErrorReceiveEvent) => {
        if (event.request.isMainFrame()) {
          this.onMainFrameError();
        }
      })
      .onHttpErrorReceive((event: OnHttpErrorReceiveEvent) => {
        if (event.request.isMainFrame()) {
          this.onMainFrameError();
        }
      })
      .onTextSelectionChange((selectionText: string) => {
        this.onSelection(selectionText);
      })
      // 点按 / 长按正文：命中图片时打开大图（ArkWeb 里 DOM click 不一定触发，改在 ArkTS 侧判定）
      .onTouch((event: TouchEvent) => {
        this.onTouchEvent(event);
      })
      .onPageEnd(() => {
        this.onPageEnd();
      })
      .onOverScroll((event: OnOverScrollEvent) => {
        this.onOverScroll(event);
      })
      // 横向滑动切文：priorityGesture + IgnoreInternal 才能抢在 ArkWeb 内部手势之前。
      .priorityGesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: this.swipeDistance })
          .onActionStart((event: GestureEvent) => {
            this.onPanStart(event);
          })
          .onActionEnd((event: GestureEvent) => {
            this.onPanEnd(event);
          }),
        GestureMask.IgnoreInternal
      )
  }
}
