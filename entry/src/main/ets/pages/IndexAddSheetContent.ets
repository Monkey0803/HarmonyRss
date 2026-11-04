import { AddFeedPanel } from '../views/AddFeedPanel';
import { SaveWebPagePanel } from '../views/SaveWebPagePanel';
import { FilterCapsule } from '../views/FilterCapsule';
import { themePalette } from '../model/ThemePalette';

const ADD_SHEET_MODES: string[] = ['feed', 'web'];
const ADD_SHEET_MODE_LABELS: ResourceStr[] = [
  $r('app.string.home_add_feed_title'),
  $r('app.string.save_web_title')
];

@ComponentV2
export struct IndexAddSheetContent {
  @Param mode: string = 'feed';
  @Param pendingText: string = '';
  @Event onMode: (value: string) => void = (value: string) => {};
  @Event onClose: () => void = () => {};
  @Event onSaved: () => void = () => {};
  @Event onSubmitted: () => void = () => {};

  build() {
    Column({ space: $r('app.float.space_s') }) {
      Row({ space: $r('app.float.space_s') }) {
        FilterCapsule({
          options: ADD_SHEET_MODES,
          labels: ADD_SHEET_MODE_LABELS,
          active: this.mode,
          stretch: true,
          onSelect: (value: string) => { this.onMode(value); }
        })
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([themePalette.accent()])
          .padding($r('app.float.space_xs'))
          .accessibilityText($r('app.string.dialog_cancel'))
          .onClick(() => { this.onClose(); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m'), top: $r('app.float.space_xl') })
      if (this.mode === 'web') {
        SaveWebPagePanel({ initialText: this.pendingText, showTitle: false, onSaved: () => this.onSaved() })
      } else {
        AddFeedPanel({ showTitle: false, initialText: this.pendingText, onSubmitResult: () => this.onSubmitted() })
      }
    }
  }
}
