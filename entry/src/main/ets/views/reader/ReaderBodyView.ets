/*
 * ReaderBodyView.ets — Reader 模式正文区（受控 HTML 文档的 ArkWeb 容器）。
 *
 * 从 ArticleDetailView 拆出：这里只负责「把一份净化后的正文文档渲染出来」以及
 * 把 Web 的滚动 / 触摸 / 加载事件原样回传给页面。正文获取、进度、标注、朗读等
 * 业务编排仍留在详情页，避免这个组件反过来依赖 ViewModel。
 */

import { webview } from '@kit.ArkWeb';
import { ReaderHighlightBridge } from '../../service/ReaderHighlight';
import { ReaderSpeechScrollBridge } from '../../service/ReaderSpeechDocument';

@ComponentV2
export struct ReaderBodyView {
  /** 净化后的正文片段；由详情页决定是否为空（为空时详情页改走纯文本兜底）。 */
  @Param html: string = '';
  /** 详情页保持同一个控制器：查找 / 朗读 / 标注 / 样式注入都要直接对它执行脚本。 */
  @Param controller: webview.WebviewController = new webview.WebviewController();
  @Param speechBridge: ReaderSpeechScrollBridge =
    new ReaderSpeechScrollBridge(() => {
    });
  @Param highlightBridge: ReaderHighlightBridge = new ReaderHighlightBridge((id: string) => {
  });
  /** 横向滑动切文的触发距离（vp）。 */
  @Param swipeDistance: number = 60;

  @Event onKey: (event: KeyEvent) => boolean = () => false;
  @Event onSelection: (text: string) => void = () => {
  };
  @Event onTouchEvent: (event: TouchEvent) => void = () => {
  };
  @Event onAttached: () => void = () => {
  };
  @Event onPageEnd: () => void = () => {
  };
  @Event onOverScroll: (event: OnOverScrollEvent) => void = () => {
  };
  @Event onLoadIntercept: (event: OnLoadInterceptEvent) => boolean = () => false;
  @Event onPanStart: (event: GestureEvent) => void = () => {
  };
  @Event onPanEnd: (event: GestureEvent) => void = () => {
  };

  build() {
    Web({ src: '', controller: this.controller })
      .width('100%')
      .height('100%')
      // Reader Web 通常会拿到焦点：在这里也挂快捷键，避免只依赖页面根节点焦点。
      .onKeyEvent((event: KeyEvent): boolean => {
        return this.onKey(event);
      })
      .darkMode(WebDarkMode.Auto)
      .javaScriptAccess(true)
      .domStorageAccess(false)
      .horizontalScrollBarAccess(false)
      .javaScriptProxy({
        object: this.speechBridge,
        name: 'hrSpeechScroll',
        methodList: ['onManualScroll'],
        controller: this.controller
      })
      // 文档内点标注：window.__hrHrCb.onClick(id)
      .javaScriptProxy({
        object: this.highlightBridge,
        name: '__hrHlCb',
        methodList: ['onHlClick'],
        controller: this.controller
      })
      .onLoadIntercept((event: OnLoadInterceptEvent): boolean => {
        return this.onLoadIntercept(event);
      })
      .onTextSelectionChange((selectionText: string) => {
        this.onSelection(selectionText);
      })
      // 点按 / 长按正文：命中图片时打开大图（ArkWeb 里 DOM click 不一定触发，改在 ArkTS 侧判定）
      .onTouch((event: TouchEvent) => {
        this.onTouchEvent(event);
      })
      .onControllerAttached(() => {
        this.onAttached();
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
