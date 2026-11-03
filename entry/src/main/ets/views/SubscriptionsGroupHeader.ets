/*
 * SubscriptionsGroupHeader.ets — 订阅源管理页的分组头（纯展示 + 事件上报，状态管理 V2）。
 *
 * 组头与组内订阅行合成一张连续卡片：组头负责上圆角，最后一个订阅行负责下圆角。
 * 整组未读与订阅数量在这里按 @Trace feeds 现算，保证后台同步后角标自动更新。
 */

import { FeedSource } from '../model/Feed';
import { groupCount, groupUnread } from '../viewmodel/FeedRowBuilder';
import { appSettings } from '../model/AppSettings';
import { offlineDownloadService } from '../service/OfflineDownloadService';
import { themePalette } from '../model/ThemePalette';

@ComponentV2
export struct SubscriptionsGroupHeader {
  /** 全量订阅源：用于现算组内数量 / 未读（读取 @Trace 字段建立观察）。 */
  @Param feeds: FeedSource[] = [];
  @Param groupName: string = '';
  @Param collapsed: boolean = false;
  /** 多选态不显示折叠 / 离线控件，左侧区域也不响应折叠。 */
  @Param selecting: boolean = false;
  @Event onToggleCollapse: () => void = () => {};

  /** 组头卡片圆角：折叠时四角都圆；展开时只圆上面两角，下面与订阅行相接。 */
  private corners(): BorderRadiuses {
    const radius: Resource = $r('app.float.radius_card');
    return {
      topLeft: radius,
      topRight: radius,
      bottomLeft: this.collapsed ? radius : 0,
      bottomRight: this.collapsed ? radius : 0
    };
  }

  private groupLabel(): ResourceStr {
    return this.groupName.length > 0 ? this.groupName : $r('app.string.group_ungrouped');
  }

  @Builder
  UnreadBadge(unread: number) {
    Text(unread.toString())
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
      .accessibilityText($r('app.string.home_unread_count', unread))
      .flexShrink(0)
  }

  build() {
    Column() {
      // 组与组之间的呼吸空间：列表项本身不加 margin，避免拖拽下标与卡片接缝互相牵扯。
      Row()
        .width('100%')
        .height($r('app.float.subs_group_gap'))

      Row({ space: $r('app.float.space_s') }) {
        Row({ space: $r('app.float.space_s') }) {
          SymbolGlyph(this.groupName.length > 0 ? $r('sys.symbol.folder_fill') : $r('sys.symbol.folder'))
            .fontSize($r('app.float.icon_size_small'))
            .fontColor([themePalette.accent()])
          Text(this.groupLabel())
            .fontSize($r('app.float.font_size_section'))
            .fontColor($r('app.color.hm_text_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '55%' })
          // 单订阅源展开时，行内已有未读角标，组头不再重复；折叠后组头是唯一入口，仍显示。
          if ((this.collapsed || groupCount(this.feeds, this.groupName) > 1) &&
            groupUnread(this.feeds, this.groupName) > 0) {
            this.UnreadBadge(groupUnread(this.feeds, this.groupName))
          }
          Text($r('app.string.home_feed_count', groupCount(this.feeds, this.groupName)))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .maxLines(1)
            .flexShrink(0)
        }
        .layoutWeight(1)
        .onClick(() => {
          if (!this.selecting) {
            this.onToggleCollapse();
          }
        })

        if (!this.selecting) {
          if (this.groupName.length > 0) {
            Text($r('app.string.subs_offline_short'))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .maxLines(1)
              .flexShrink(0)
            Toggle({ type: ToggleType.Switch, isOn: appSettings.offlineGroups.indexOf(this.groupName) >= 0 })
              .selectedColor(themePalette.fill())
              .accessibilityText($r('app.string.offline_group'))
              .onChange((value: boolean) => {
                offlineDownloadService.toggleGroup(this.groupName, value);
                if (value) {
                  offlineDownloadService.prepare(this.feeds).catch(() => {});
                }
              })
          }
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize($r('app.float.icon_size_small'))
              .fontColor([themePalette.accent()])
              .rotate({ angle: this.collapsed ? 0 : 90 })
          }
          .width(40)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .accessibilityText(this.collapsed
            ? $r('app.string.subs_group_expand')
            : $r('app.string.subs_group_collapse'))
          .onClick(() => {
            this.onToggleCollapse();
          })
        }
      }
      .width('100%')
      .height($r('app.float.subs_group_row_height'))
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_xs') })
      .backgroundColor($r('app.color.hm_card_background'))
      .borderRadius(this.corners())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
