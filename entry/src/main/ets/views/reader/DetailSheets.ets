/*
 * DetailSheets.ets — 详情页里几个「纯展示 / 薄适配」的第二页内容。
 *
 * 只收数据与回调，不读 ViewModel：
 *   - 目录、来源、标签选择、分享、翻译、阅读排版；
 * 标注列表与标注编辑仍留在详情页（与编辑态、正文联动强）。
 */

import { common } from '@kit.AbilityKit';
import { GroupSource } from '../../model/Dedupe';
import { themePalette } from '../../model/ThemePalette';
import { TocEntry } from '../../service/ReaderToc';
import { ShareSheet } from '../ShareSheet';
import { TranslateSheet } from '../TranslateSheet';
import { TagPickerSheet } from '../TagPickerSheet';
import { ReadSettingsSheet } from '../ReadSettingsSheet';

/** 目录：h1–h4 按层级缩进，点击跳转。 */
@ComponentV2
export struct TocSheetView {
  @Param toc: TocEntry[] = [];
  @Event onGoto: (index: number) => void = () => {
  };

  build() {
    Column({ space: $r('app.float.space_m') }) {
      Text($r('app.string.toc_title'))
        .fontSize($r('app.float.font_size_section'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      List() {
        ForEach(this.toc, (entry: TocEntry) => {
          ListItem() {
            Row({ space: $r('app.float.space_s') }) {
              Row()
                .width(Math.max(0, entry.level - 1) * 14)
                .height(1)
              Text(entry.text)
                .fontSize(entry.level <= 2
                  ? $r('app.float.font_size_body') : $r('app.float.font_size_caption'))
                .fontWeight(entry.level === 2 ? FontWeight.Medium : FontWeight.Regular)
                .fontColor($r('app.color.hm_text_primary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: $r('app.float.space_s'), bottom: $r('app.float.space_s') })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.onGoto(entry.index);
            })
          }
        }, (entry: TocEntry) => entry.index.toString() + '_' + entry.text)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({
      left: $r('app.float.space_l'),
      right: $r('app.float.space_l'),
      top: $r('app.float.space_m')
    })
    .alignItems(HorizontalAlign.Start)
  }
}

/** 来源：跨源去重后同一篇文章的全部来源，点击用浏览器打开。 */
@ComponentV2
export struct SourcesPanelView {
  @Param sources: GroupSource[] = [];
  /** 当前文章 id：命中时打「当前」标记。 */
  @Param currentId: string = '';
  @Event onOpen: (source: GroupSource) => void = () => {
  };

  build() {
    Column({ space: $r('app.float.space_m') }) {
      Text($r('app.string.dedupe_sources_title'))
        .fontSize($r('app.float.font_size_section'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      if (this.sources.length === 0) {
        Text($r('app.string.dedupe_group_empty'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      } else {
        // List 的 space 只收 string|number，间距放在条目 margin 上。
        List() {
          ForEach(this.sources, (source: GroupSource) => {
            ListItem() {
              Column({ space: $r('app.float.space_xs') }) {
                Row({ space: $r('app.float.space_s') }) {
                  Text(source.feedTitle.length > 0
                    ? source.feedTitle
                    : $r('app.string.dedupe_source_label'))
                    .fontSize($r('app.float.font_size_body'))
                    .fontColor($r('app.color.hm_text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)

                  if (source.articleId === this.currentId) {
                    Text($r('app.string.dedupe_source_current'))
                      .fontSize($r('app.float.font_size_caption'))
                      .fontColor(themePalette.accent())
                      .height($r('app.float.value_chip_height'))
                      .padding({ left: $r('app.float.space_s'), right: $r('app.float.space_s') })
                      .backgroundColor($r('app.color.hm_value_chip_background'))
                      .borderRadius($r('app.float.radius_chip'))
                  }
                }
                .width('100%')

                if (source.link.length > 0) {
                  Text(source.link)
                    .fontSize($r('app.float.font_size_caption'))
                    .fontColor(themePalette.accent())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
              }
              .width('100%')
              .padding($r('app.float.space_m'))
              .backgroundColor($r('app.color.hm_card_background'))
              .borderRadius($r('app.float.radius_card'))
              .alignItems(HorizontalAlign.Start)
              .onClick(() => {
                this.onOpen(source);
              })
            }
            .margin({ bottom: $r('app.float.space_s') })
          }, (source: GroupSource) => source.articleId)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding($r('app.float.space_l'))
    .alignItems(HorizontalAlign.Start)
  }
}

/** 标签选择器：复用 TagPickerSheet（详情页 / 批量打标同一套）。 */
@ComponentV2
export struct TagSheetView {
  @Param selectedTagIds: string[] = [];
  @Event onConfirm: (ids: string[]) => void = () => {
  };

  build() {
    TagPickerSheet({
      selectedTagIds: this.selectedTagIds,
      onConfirm: (ids: string[]): void => {
        this.onConfirm(ids);
      }
    })
  }
}

/** 统一分享面板（上下文由详情页在打开前写入 ShareViewModel）。 */
@ComponentV2
export struct ShareSheetView {
  @Param ability: common.UIAbilityContext | undefined = undefined;
  @Event onClose: () => void = () => {
  };

  build() {
    ShareSheet({
      ability: this.ability,
      onClose: (): void => {
        this.onClose();
      }
    })
  }
}

/** 正文翻译面板：结果已由 ViewModel 就绪（缓存或刚发起）。 */
@ComponentV2
export struct TranslateSheetView {
  @Event onClose: () => void = () => {
  };
  @Event onOpenSettings: () => void = () => {
  };

  build() {
    TranslateSheet({
      onClose: (): void => {
        this.onClose();
      },
      onOpenSettings: (): void => {
        this.onOpenSettings();
      }
    })
  }
}

/** 阅读排版面板。 */
@ComponentV2
export struct ReadSheetView {
  @Param webMode: boolean = false;
  @Event onApply: () => void = () => {
  };

  build() {
    ReadSettingsSheet({
      webMode: this.webMode,
      onApply: (): void => {
        this.onApply();
      }
    })
  }
}
