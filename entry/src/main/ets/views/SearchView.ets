/*
 * SearchView.ets — 全局全文检索页（纯展示 + 事件上报）。
 *
 * 输入框 + 历史 chips + 状态 chips + 结果列表（标题 / 来源 / 时间 / 命中片段）+ 触底续页。
 * 命中词在片段中用 Span 强调；点击结果打开文章并定位到正文首个命中（见 FeedViewModel.openSearchHit）。
 */

import { common } from '@kit.AbilityKit';
import { SearchHit, SearchState } from '../model/Search';
import { searchViewModel } from '../viewmodel/SearchViewModel';
import { DateUtil } from '../common/utils/DateUtil';
import { safeArea } from '../service/SafeAreaController';
import { RouterConstants } from '../common/constants/RouterConstants';

/** 片段分片：一段普通文本或一段命中词。 */
class SnippetSegment {
  readonly text: string;
  readonly hit: boolean;

  constructor(text: string, hit: boolean) {
    this.text = text;
    this.hit = hit;
  }
}

/** 命中片段：按关键词切片，命中词用品牌色 + 中等字重强调。 */
@ComponentV2
struct SnippetText {
  @Param text: string = '';
  @Param term: string = '';

  private segments(): SnippetSegment[] {
    const result: SnippetSegment[] = [];
    const source: string = this.text;
    const term: string = this.term.trim();
    if (term.length === 0 || source.length === 0) {
      if (source.length > 0) {
        result.push(new SnippetSegment(source, false));
      }
      return result;
    }
    const lowerSource: string = source.toLowerCase();
    const lowerTerm: string = term.toLowerCase();
    let from: number = 0;
    let guard: number = 0;
    while (from < source.length && guard < 200) {
      guard += 1;
      const index: number = lowerSource.indexOf(lowerTerm, from);
      if (index < 0) {
        result.push(new SnippetSegment(source.substring(from), false));
        break;
      }
      if (index > from) {
        result.push(new SnippetSegment(source.substring(from, index), false));
      }
      result.push(new SnippetSegment(source.substring(index, index + term.length), true));
      from = index + term.length;
    }
    return result;
  }

  build() {
    Text() {
      ForEach(this.segments(), (segment: SnippetSegment, index: number) => {
        Span(segment.text)
          .fontColor(segment.hit ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary'))
          .fontWeight(segment.hit ? FontWeight.Medium : FontWeight.Regular)
      }, (segment: SnippetSegment, index: number) => index.toString())
    }
    .fontSize($r('app.float.font_size_caption'))
    .maxLines(3)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
    .width('100%')
  }
}

@ComponentV2
export struct SearchView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  /** 输入框草稿（受控）。 */
  @Local draft: string = '';
  /** 打开命中在途（避免连点重复 push）。 */
  @Local opening: boolean = false;

  aboutToAppear(): void {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context !== undefined) {
      searchViewModel.init(context);
    }
    if (searchViewModel.raw.length > 0) {
      this.draft = searchViewModel.raw;
    }
  }

  private submit(text: string): void {
    this.draft = text;
    if (text.trim().length === 0) {
      searchViewModel.clearResults();
      return;
    }
    searchViewModel.submit(text);
  }

  private async openHit(hit: SearchHit): Promise<void> {
    if (this.opening) {
      return;
    }
    this.opening = true;
    try {
      const ok: boolean = await searchViewModel.openHit(hit);
      if (ok) {
        this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_ARTICLE, ''));
      }
    } finally {
      this.opening = false;
    }
  }

  /** 状态筛选 chips 的定义。 */
  private stateOptions(): string[] {
    return [SearchState.ALL, SearchState.UNREAD, SearchState.STARRED, SearchState.SAVED];
  }

  private stateLabel(state: string): ResourceStr {
    if (state === SearchState.UNREAD) {
      return $r('app.string.search_filter_unread');
    }
    if (state === SearchState.STARRED) {
      return $r('app.string.search_filter_starred');
    }
    if (state === SearchState.SAVED) {
      return $r('app.string.search_filter_saved');
    }
    return $r('app.string.search_filter_all');
  }

  @Builder
  StateChip(state: string) {
    Text(this.stateLabel(state))
      .fontSize($r('app.float.font_size_caption'))
      .fontColor(searchViewModel.activeState === state
        ? $r('app.color.hm_on_brand')
        : $r('app.color.hm_text_primary'))
      .padding({
        left: $r('app.float.space_m'),
        right: $r('app.float.space_m'),
        top: $r('app.float.space_xs'),
        bottom: $r('app.float.space_xs')
      })
      .backgroundColor(searchViewModel.activeState === state
        ? $r('app.color.hm_brand')
        : $r('app.color.hm_value_chip_background'))
      .borderRadius($r('app.float.radius_chip'))
      .onClick(() => {
        searchViewModel.setState(state);
      })
  }

  @Builder
  SearchHeader() {
    Column({ space: $r('app.float.space_s') }) {
      Row({ space: $r('app.float.space_s') }) {
        TextInput({ text: this.draft, placeholder: $r('app.string.search_hint') })
          .type(InputType.Normal)
          .fontSize($r('app.float.font_size_body'))
          .layoutWeight(1)
          .enterKeyType(EnterKeyType.Search)
          .onChange((value: string) => {
            this.draft = value;
            if (value.trim().length === 0) {
              searchViewModel.clearResults();
            }
          })
          .onSubmit((enterKey: EnterKeyType) => {
            this.submit(this.draft);
          })
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([$r('app.color.hm_brand')])
          .padding($r('app.float.space_s'))
          .onClick(() => {
            this.submit(this.draft);
          })
      }
      .width('100%')

      Text($r('app.string.search_syntax_hint'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      if (!searchViewModel.indexed) {
        Text($r('app.string.search_index_fallback'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      }

      if (searchViewModel.history.length > 0) {
        Row() {
          Text($r('app.string.search_history'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
          Blank()
          Text($r('app.string.search_clear_history'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_brand'))
            .onClick(() => {
              searchViewModel.clearHistory();
            })
        }
        .width('100%')

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(searchViewModel.history, (item: string) => {
            Text(item)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({
                left: $r('app.float.space_m'),
                right: $r('app.float.space_m'),
                top: $r('app.float.space_xs'),
                bottom: $r('app.float.space_xs')
              })
              .margin({ right: $r('app.float.space_s'), bottom: $r('app.float.space_s') })
              .backgroundColor($r('app.color.hm_value_chip_background'))
              .borderRadius($r('app.float.radius_chip'))
              .onClick(() => {
                this.submit(item);
              })
          }, (item: string) => item)
        }
        .width('100%')
      }

      Row({ space: $r('app.float.space_s') }) {
        ForEach(this.stateOptions(), (state: string) => {
          this.StateChip(state)
        }, (state: string) => state)
        Blank()
        if (searchViewModel.total > 0) {
          Text($r('app.string.search_result_count', searchViewModel.total))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  /** 一条结果：标题 + 来源/时间 + 命中片段。 */
  @Builder
  HitRow(hit: SearchHit) {
    Column({ space: $r('app.float.space_xs') }) {
      Text(hit.title.length > 0 ? hit.title : hit.snippet)
        .fontSize($r('app.float.font_size_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row({ space: $r('app.float.space_s') }) {
        Text(hit.feedTitle)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (hit.publishedAt > 0) {
          Text(DateUtil.format(hit.publishedAt))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
        if (hit.starred) {
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize($r('app.float.icon_size_tiny'))
            .fontColor([$r('app.color.hm_brand')])
        }
      }
      .width('100%')

      if (hit.snippet.length > 0) {
        SnippetText({ text: hit.snippet, term: searchViewModel.currentTerm })
      }
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .margin({ bottom: $r('app.float.space_s') })
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openHit(hit);
    })
  }

  /** 空态：未输入 / 无结果 / 失败。 */
  @Builder
  EmptyState() {
    Column({ space: $r('app.float.space_s') }) {
      if (searchViewModel.failed) {
        Text($r('app.string.search_error'))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_danger'))
      } else if (searchViewModel.searching) {
        Text($r('app.string.search_searching'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
      } else if (searchViewModel.showEmpty()) {
        Text($r('app.string.search_no_result'))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_secondary'))
      } else if (searchViewModel.showHint()) {
        Text($r('app.string.search_empty'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .padding({ top: $r('app.float.space_2xl'), bottom: $r('app.float.space_2xl') })
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        Row().width('100%').height(safeArea.contentTopInsetVp)

        this.SearchHeader()

        Column() {
          if (searchViewModel.hits.length === 0) {
            this.EmptyState()
          } else {
            ForEach(searchViewModel.hits, (hit: SearchHit) => {
              this.HitRow(hit)
            }, (hit: SearchHit) => hit.articleId)

            if (searchViewModel.hasMore) {
              Text(searchViewModel.searching
                ? $r('app.string.search_searching')
                : $r('app.string.list_load_more'))
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.hm_text_secondary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding($r('app.float.space_l'))
            }
          }
        }
        .width('100%')
        .margin({ top: $r('app.float.space_m') })

        Blank().height(safeArea.contentBottomInsetVp)
      }
      .width('100%')
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .clip(false)
    // 触底续页
    .onReachEnd(() => {
      searchViewModel.loadMore();
    })
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
