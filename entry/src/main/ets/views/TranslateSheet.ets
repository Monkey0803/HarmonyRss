/*
 * TranslateSheet.ets — 阅读页翻译面板（半模态内容，纯状态管理 V2）。
 *
 * 只读 TranslationViewModel：
 *   - 选段结果（如有）置顶展示；
 *   - 整篇译文按段落与原文对照，支持「只看译文」；
 *   - 未开启 / Key 无效时给可操作提示与「打开翻译设置」入口，不阻塞阅读。
 */

import { TranslationErrorCode, TranslationParagraph } from '../model/Translation';
import { translationViewModel } from '../viewmodel/TranslationViewModel';
import { languageText, translationErrorText } from '../common/utils/TranslationText';

const STATUS_LOADING: string = 'loading';
const STATUS_READY: string = 'ready';
const STATUS_ERROR: string = 'error';

@ComponentV2
export struct TranslateSheet {
  @Event onClose: () => void = () => {
  };
  @Event onOpenSettings: () => void = () => {
  };

  private hasSelection(): boolean {
    return translationViewModel.selectionOriginal.length > 0;
  }

  private selectionFailed(): boolean {
    return translationViewModel.selectionStatus === STATUS_ERROR;
  }

  private canOpenSettings(): boolean {
    const code: string = translationViewModel.errorCode;
    return code === TranslationErrorCode.DISABLED || code === TranslationErrorCode.NOT_CONFIGURED ||
      code === TranslationErrorCode.AUTH;
  }

  private selectionCanOpenSettings(): boolean {
    const code: string = translationViewModel.selectionError;
    return code === TranslationErrorCode.DISABLED || code === TranslationErrorCode.NOT_CONFIGURED ||
      code === TranslationErrorCode.AUTH;
  }

  @Builder
  Header() {
    Row({ space: $r('app.float.space_s') }) {
      SymbolGlyph($r('sys.symbol.translate'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([$r('app.color.hm_brand')])
      Text($r('app.string.translate_sheet_title'))
        .fontSize($r('app.float.font_size_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .layoutWeight(1)
      if (translationViewModel.status === STATUS_READY) {
        Text(languageText(translationViewModel.sourceLang))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        SymbolGlyph($r('sys.symbol.arrow_right'))
          .fontSize($r('app.float.icon_size_tiny'))
          .fontColor([$r('app.color.hm_text_secondary')])
        Text(languageText(translationViewModel.targetLang))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        if (translationViewModel.fromCache) {
          Text($r('app.string.translate_cached'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_brand'))
        }
      }
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([$r('app.color.hm_text_secondary')])
        .padding($r('app.float.space_xs'))
        .onClick(() => {
          this.onClose();
        })
    }
    .width('100%')
    .padding({ bottom: $r('app.float.space_s') })
  }

  /** 选段翻译卡片：原文 + 译文 / 加载 / 错误。 */
  @Builder
  SelectionCard() {
    if (this.hasSelection()) {
      Column({ space: $r('app.float.space_xs') }) {
        Text($r('app.string.translate_selection_title'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .width('100%')
        Text(translationViewModel.selectionOriginal)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
        if (translationViewModel.selectionStatus === STATUS_LOADING) {
          LoadingProgress()
            .width($r('app.float.web_loading_size'))
            .height($r('app.float.web_loading_size'))
            .color($r('app.color.hm_brand'))
        } else if (this.selectionFailed()) {
          Text(translationErrorText(translationViewModel.selectionError))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_danger'))
            .width('100%')
          if (this.selectionCanOpenSettings()) {
            Button($r('app.string.translate_open_settings'))
              .buttonStyle(ButtonStyleMode.TEXTUAL)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_brand'))
              .padding({ left: 0 })
              .onClick(() => {
                this.onOpenSettings();
              })
          }
        } else if (translationViewModel.selectionTranslated.length > 0) {
          Text(translationViewModel.selectionTranslated)
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_text_primary'))
            .width('100%')
            .copyOption(CopyOptions.LocalDevice)
        }
      }
      .width('100%')
      .padding($r('app.float.space_m'))
      .margin({ bottom: $r('app.float.space_m') })
      .backgroundColor($r('app.color.hm_card_background'))
      .borderRadius($r('app.float.radius_card'))
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 错误提示：开关 / 配置问题给设置入口，其它给重试。 */
  @Builder
  ErrorCard() {
    Column({ space: $r('app.float.space_s') }) {
      Text(translationViewModel.errorCode === TranslationErrorCode.DISABLED
        ? $r('app.string.translate_error_disabled_title')
        : translationErrorText(translationViewModel.errorCode))
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')
      if (translationViewModel.errorCode === TranslationErrorCode.DISABLED) {
        Text($r('app.string.translate_error_disabled_desc'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      }
      Row({ space: $r('app.float.space_s') }) {
        if (this.canOpenSettings()) {
          Button($r('app.string.translate_open_settings'))
            .buttonStyle(ButtonStyleMode.NORMAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_on_brand'))
            .backgroundColor($r('app.color.hm_brand'))
            .onClick(() => {
              this.onOpenSettings();
            })
        } else {
          Button($r('app.string.translate_retry'))
            .buttonStyle(ButtonStyleMode.NORMAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_on_brand'))
            .backgroundColor($r('app.color.hm_brand'))
            .onClick(() => {
              translationViewModel.retry();
            })
        }
      }
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 段落对照行：原文（次要色）+ 译文（主色）。 */
  @Builder
  ParagraphRow(item: TranslationParagraph) {
    Column({ space: $r('app.float.space_xs') }) {
      if (!translationViewModel.onlyTranslation) {
        Text(item.original)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }
      Text(item.translated.length > 0 ? item.translated : item.original)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .padding({
      top: $r('app.float.space_s'),
      bottom: $r('app.float.space_s')
    })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      this.Header()
      Scroll() {
        Column() {
          this.SelectionCard()

          if (translationViewModel.status === STATUS_LOADING) {
            Column({ space: $r('app.float.space_s') }) {
              LoadingProgress()
                .width($r('app.float.web_loading_size'))
                .height($r('app.float.web_loading_size'))
                .color($r('app.color.hm_brand'))
              Text($r('app.string.translate_loading'))
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.hm_text_secondary'))
            }
            .width('100%')
            .padding($r('app.float.space_xl'))
          } else if (translationViewModel.status === STATUS_ERROR) {
            this.ErrorCard()
          } else if (translationViewModel.status === STATUS_READY) {
            if (translationViewModel.truncated) {
              Text($r('app.string.translate_truncated'))
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.hm_text_secondary'))
                .width('100%')
                .margin({ bottom: $r('app.float.space_s') })
            }
            Row() {
              Text($r('app.string.translate_only_translation'))
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.hm_text_secondary'))
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: translationViewModel.onlyTranslation })
                .selectedColor($r('app.color.hm_brand'))
                .onChange((value: boolean) => {
                  translationViewModel.onlyTranslation = value;
                })
            }
            .width('100%')
            .padding({ bottom: $r('app.float.space_s') })

            ForEach(translationViewModel.paragraphs, (item: TranslationParagraph) => {
              this.ParagraphRow(item)
              Divider().color($r('app.color.hm_divider'))
            }, (item: TranslationParagraph, index: number) => index.toString())

            Button($r('app.string.translate_retry'))
              .width('100%')
              .height($r('app.float.row_height'))
              .buttonStyle(ButtonStyleMode.TEXTUAL)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_brand'))
              .margin({ top: $r('app.float.space_m') })
              .onClick(() => {
                translationViewModel.retry();
              })
          }
        }
        .width('100%')
        .padding({ bottom: $r('app.float.space_xl') })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    .alignItems(HorizontalAlign.Start)
  }
}
