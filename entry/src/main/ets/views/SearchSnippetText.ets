import { themePalette } from '../model/ThemePalette';

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
export struct SnippetText {
  @Param text: string = '';
  @Param term: string = '';

  @Computed
  get segments(): SnippetSegment[] {
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
      ForEach(this.segments, (segment: SnippetSegment, index: number) => {
        Span(segment.text)
          .fontColor(segment.hit ? themePalette.accent() : $r('app.color.hm_text_secondary'))
          .fontWeight(segment.hit ? FontWeight.Medium : FontWeight.Regular)
      }, (segment: SnippetSegment, index: number) => index.toString())
    }
    .fontSize($r('app.float.font_size_caption'))
    .maxLines(3)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
    .width('100%')
  }
}
