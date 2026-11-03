/*
 * FeedIcon.ets — 订阅源行首的站点图标（纯展示，状态管理 V2）。
 *
 * 加载顺序：feed 自带图标 → /favicon.ico → /apple-touch-icon.png → 首字母头像。
 * 只在行首次进入可视区时发起请求；失败按序换下一个候选，全部失败保留头像。
 * 不做第三方 favicon 服务，也不写磁盘缓存（图标是展示信息，重复打开时由 Image 自身缓存）。
 */

import { FeedSource } from '../model/Feed';
import { UrlText } from '../common/utils/UrlText';
import { feedAvatarColor, feedInitial } from '../common/utils/FeedAvatar';

@ComponentV2
export struct FeedIcon {
  @Require @Param feed: FeedSource;
  @Param iconSize: number = 30;

  /** 当前尝试的图片地址；空串表示只显示头像。 */
  @Local src: string = '';
  /** 已尝试到的候选下标。 */
  @Local index: number = 0;
  @Local started: boolean = false;
  @Local visible: boolean = false;
  /** 头像是否仍显示：图片 onComplete 后隐藏。 */
  @Local showAvatar: boolean = true;

  /** 图标字段变化（抓取后补上图标 / 站点变更）时重新走候选。 */
  @Monitor('feed.iconUrl', 'feed.siteUrl')
  onSourceChanged(): void {
    this.index = 0;
    this.src = '';
    this.started = false;
    this.showAvatar = true;
    if (this.visible) {
      this.start();
    }
  }

  /** 候选地址：feed 自带图标优先，其后是同源 favicon 与 apple-touch-icon。 */
  private candidates(): string[] {
    const list: string[] = [];
    const icon: string = this.feed.iconUrl.trim();
    if (icon.length > 0) {
      list.push(icon);
    }
    const base: string = this.feed.siteUrl.length > 0 ? this.feed.siteUrl : this.feed.url;
    const origin: string = UrlText.origin(base);
    if (origin.length > 0) {
      const favicon: string = origin + '/favicon.ico';
      if (list.indexOf(favicon) < 0) {
        list.push(favicon);
      }
      const touchIcon: string = origin + '/apple-touch-icon.png';
      if (list.indexOf(touchIcon) < 0) {
        list.push(touchIcon);
      }
    }
    return list;
  }

  private start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.index = 0;
    this.showAvatar = true;
    const list: string[] = this.candidates();
    this.src = list.length > 0 ? list[0] : '';
  }

  /** 当前候选失败：换下一个；全部失败回到头像。 */
  private next(): void {
    const list: string[] = this.candidates();
    this.index += 1;
    if (this.index < list.length) {
      this.src = list[this.index];
      return;
    }
    this.src = '';
    this.showAvatar = true;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.showAvatar) {
        Text(feedInitial(this.feed.title))
          .fontSize(this.iconSize * 0.42)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
          .width(this.iconSize)
          .height(this.iconSize)
          .textAlign(TextAlign.Center)
          .borderRadius($r('app.float.subs_avatar_radius'))
          .backgroundColor(feedAvatarColor(this.feed.title))
      }
      if (this.src.length > 0) {
        Image(this.src)
          .width(this.iconSize)
          .height(this.iconSize)
          .borderRadius($r('app.float.subs_avatar_radius'))
          .objectFit(ImageFit.Contain)
          .interpolation(ImageInterpolation.Medium)
          .draggable(false)
          .onComplete(() => {
            this.showAvatar = false;
          })
          .onError(() => {
            this.next();
          })
      }
    }
    .width(this.iconSize)
    .height(this.iconSize)
    .accessibilityLevel('no')
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, ratio: number) => {
      if (isVisible && !this.visible) {
        this.visible = true;
        this.start();
      }
    })
  }
}
