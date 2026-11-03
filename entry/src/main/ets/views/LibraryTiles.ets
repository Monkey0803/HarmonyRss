/*
 * LibraryTiles.ets — 「资料库」快捷入口卡（发现 / 标签 / 智能文件夹 / 规则）。
 *
 * 为什么要组件化：四个入口的计数来自三个 @ObservedV2 单例，组件自己读计数才能随增删自动刷新；
 * 若在页面里用多参 @Builder 传计数，参数变化不会触发刷新（ArkUI @Builder 参数规则）。
 */

import { RouterConstants } from '../common/constants/RouterConstants';
import { tagViewModel } from '../viewmodel/TagViewModel';
import { smartFolderViewModel } from '../viewmodel/SmartFolderViewModel';
import { ruleViewModel } from '../viewmodel/RuleViewModel';
import { themePalette } from '../model/ThemePalette';

@ComponentV2
struct LibraryTile {
  @Param icon: Resource = $r('sys.symbol.rays');
  @Param label: ResourceStr = '';
  @Param count: number = 0;
  @Event onOpen: () => void = () => {};

  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(this.icon)
          .fontSize($r('app.float.subs_tile_icon_size'))
          .fontColor([themePalette.accent()])
        if (this.count > 0) {
          Text(this.count.toString())
            .fontSize($r('app.float.subs_tile_badge_size'))
            .fontColor(themePalette.accent())
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .backgroundColor(themePalette.tint())
            .borderRadius($r('app.float.radius_chip'))
            .offset({ x: 15, y: -10 })
        }
      }
      .width(44)
      .height(28)

      Text(this.label)
        .fontSize($r('app.float.subs_tile_label_size'))
        .fontColor($r('app.color.hm_text_primary'))
        .fontWeight(FontWeight.Medium)
        .maxLines(2)
        .lineHeight(15)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 4, right: 4 })
    .onClick(() => {
      this.onOpen();
    })
  }
}

@ComponentV2
export struct LibraryQuickAccess {
  @Event onOpen: (route: string) => void = () => {};

  /** 只读计数：读取 @Trace 数组长度，增删后本组件自动刷新。 */
  private countOf(id: string): number {
    if (id === 'tags') {
      return tagViewModel.tags.length;
    }
    if (id === 'folders') {
      return smartFolderViewModel.folders.length;
    }
    if (id === 'rules') {
      return ruleViewModel.rules.length;
    }
    return 0;
  }

  build() {
    Row() {
      LibraryTile({
        icon: $r('sys.symbol.rays'),
        label: $r('app.string.discover_entry'),
        count: 0,
        onOpen: () => {
          this.onOpen(RouterConstants.PAGE_DISCOVER);
        }
      })
      LibraryTile({
        icon: $r('sys.symbol.label'),
        label: $r('app.string.tag_title'),
        count: this.countOf('tags'),
        onOpen: () => {
          this.onOpen(RouterConstants.PAGE_TAGS);
        }
      })
      LibraryTile({
        icon: $r('sys.symbol.folder_fill'),
        label: $r('app.string.smart_folder_title'),
        count: this.countOf('folders'),
        onOpen: () => {
          this.onOpen(RouterConstants.PAGE_SMART_FOLDERS);
        }
      })
      LibraryTile({
        icon: $r('sys.symbol.slider_horizontal_2'),
        label: $r('app.string.rule_title'),
        count: this.countOf('rules'),
        onOpen: () => {
          this.onOpen(RouterConstants.PAGE_RULES);
        }
      })
    }
    .width('100%')
    .height($r('app.float.subs_tile_card_height'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .clip(true)
  }
}
