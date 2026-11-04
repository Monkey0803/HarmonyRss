/* Subscription row status and unread badge; the parent owns editing and navigation. */
import { FeedSource } from '../model/Feed';
import { DateUtil } from '../common/utils/DateUtil';
import { FeedErrorText } from '../common/utils/FeedErrorText';
import { UrlText } from '../common/utils/UrlText';
import { themePalette } from '../model/ThemePalette';

@ComponentV2
export struct SubscriptionCountBadge {
  @Require @Param feed: FeedSource;

  build() {
    if (this.feed.unreadCount > 0) {
      Text(this.feed.unreadCount.toString())
        .fontSize($r('app.float.font_size_caption'))
        .fontColor(themePalette.accent())
        .padding({
          left: $r('app.float.space_s'),
          right: $r('app.float.space_s'),
          top: $r('app.float.space_xxs'),
          bottom: $r('app.float.space_xxs')
        })
        .backgroundColor(themePalette.tint())
        .borderRadius($r('app.float.radius_chip'))
        .accessibilityText($r('app.string.home_unread_count', this.feed.unreadCount))
        .flexShrink(0)
    }
  }
}

@ComponentV2
export struct SubscriptionFeedStatus {
  @Require @Param feed: FeedSource;

  private feedHost(): string {
    const host: string = UrlText.host(this.feed.url);
    return host.length > 0 ? host : this.feed.url;
  }

  build() {
    Column() {
      Row({ space: $r('app.float.space_xs') }) {
        Text(this.feedHost())
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (!this.feed.enabled) {
          Text($r('app.string.feed_settings_disabled'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .flexShrink(0)
        } else if (this.feed.failureCount > 0) {
          Text($r('app.string.health_failure_count', this.feed.failureCount))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_danger'))
            .flexShrink(0)
        } else if (this.feed.lastUpdated > 0) {
          Text(DateUtil.formatShort(this.feed.lastUpdated))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .maxLines(1)
            .flexShrink(0)
            .accessibilityText($r('app.string.health_last_success', DateUtil.format(this.feed.lastUpdated)))
        } else {
          Text($r('app.string.health_never'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .maxLines(1)
            .flexShrink(0)
        }
      }
      .width('100%')

      if (this.feed.lastError.length > 0) {
        Text(FeedErrorText.of(this.feed.lastErrorCode))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
