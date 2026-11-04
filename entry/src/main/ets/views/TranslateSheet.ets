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
import { themePalette } from '../model/ThemePalette';
import { safeArea } from '../service/SafeAreaController';
import { appSettings } from '../model/AppSettings';
import { TRANSLATE_TARGET_OPTIONS } from '../model/SettingsOptions';
import { settingsStore } from '../service/SettingsStore';
import { MaterialController } from '../service/MaterialController';
import { AppMenu } from '../common/components/AppMenu';
import { choiceMenu } from '../common/components/ChoiceMenu';
import { ChoiceValueChip } from '../common/components/ChoiceField';

const STATUS_LOADING: string = 'loading';
const STATUS_READY: string = 'ready';
const STATUS_ERROR: string = 'error';

@ComponentV2
export struct TranslateSheet {
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

  private async pickTarget(id: string): Promise<void> {
    if (id === appSettings.translateTargetLang) {
      return;
    }
    appSettings.translateTargetLang = id;
    settingsStore.save();
    await translationViewModel.reload();
  }

  @Builder
  TargetMenu() {
    AppMenu(choiceMenu(TRANSLATE_TARGET_OPTIONS, appSettings.translateTargetLang, (id: string) => {
      this.pickTarget(id);
    }));
  }

  @Builder
  Header() {
    Column({ space: $r('app.float.space_xs') }) {
      Row({ space: $r('app.float.space_s') }) {
        SymbolGlyph($r('sys.symbol.translate'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([themePalette.accent()])
        Text($r('app.string.translate_sheet_title'))
          .fontSize($r('app.float.font_size_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hm_text_primary'))
          .layoutWeight(1)
        Row() {
          ChoiceValueChip({ label: TRANSLATE_TARGET_OPTIONS.labelOf(appSettings.translateTargetLang) })
        }
        .bindMenu(this.TargetMenu(),
          MaterialController.menuOptions({ placement: Placement.BottomRight }, appSettings.immersiveOn))
      }
      .width('100%')
      if (translationViewModel.status === STATUS_READY) {
        Row({ space: $r('app.float.space_xs') }) {
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
              .fontColor(themePalette.accent())
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ bottom: $r('app.float.space_s') })
  }

  /** 选段翻译卡片：原文 + 译文 / 加载 / 错误。 */
  @Builder
  SelectionCard() {
    if (this.hasSelection()) {
      Column({ space: $r('app.float.space_s') }) {
        Text($r('app.string.translate_selection_title'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(themePalette.accent())
          .width('100%')
        Text(translationViewModel.selectionOriginal)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
        if (translationViewModel.selectionStatus === STATUS_LOADING) {
          LoadingProgress()
            .width($r('app.float.web_loading_size'))
            .height($r('app.float.web_loading_size'))
            .color(themePalette.accent())
        } else if (this.selectionFailed()) {
          Text(translationErrorText(translationViewModel.selectionError))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_danger'))
            .width('100%')
          if (this.selectionCanOpenSettings()) {
            Button($r('app.string.translate_open_settings'))
              .buttonStyle(ButtonStyleMode.TEXTUAL)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor(themePalette.accent())
              .padding({ left: 0 })
              .onClick(() => {
                this.onOpenSettings();
              })
          }
        } else if (translationViewModel.selectionTranslated.length > 0) {
          Text(translationViewModel.selectionTranslated)
            .fontSize($r('app.float.font_size_body'))
            .fontWeight(FontWeight.Medium)
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
            .backgroundColor(themePalette.fill())
            .onClick(() => {
              this.onOpenSettings();
            })
        } else {
          Button($r('app.string.translate_retry'))
            .buttonStyle(ButtonStyleMode.NORMAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_on_brand'))
            .backgroundColor(themePalette.fill())
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
    Column({ space: $r('app.float.space_s') }) {
      if (!translationViewModel.onlyTranslation) {
        Text(item.original)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }
      Text(item.translated.length > 0 ? item.translated : item.original)
        .fontSize($r('app.float.font_size_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .margin({ bottom: $r('app.float.space_s') })
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      this.Header()
      if (translationViewModel.status === STATUS_READY) {
        Row() {
          Text($r('app.string.translate_only_translation'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: translationViewModel.onlyTranslation })
            .selectedColor(themePalette.fill())
            .onChange((value: boolean) => {
              translationViewModel.onlyTranslation = value;
            })
        }
        .width('100%')
        .padding({ bottom: $r('app.float.space_s') })
      }
      Scroll() {
        Column() {
          this.SelectionCard()

          if (translationViewModel.status === STATUS_LOADING) {
            Column({ space: $r('app.float.space_s') }) {
              LoadingProgress()
                .width($r('app.float.web_loading_size'))
                .height($r('app.float.web_loading_size'))
                .color(themePalette.accent())
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
            ForEach(translationViewModel.paragraphs, (item: TranslationParagraph) => {
              this.ParagraphRow(item)
            }, (item: TranslationParagraph, index: number) => index.toString())
          }
        }
        .width('100%')
        .padding({ bottom: $r('app.float.space_s') })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      if (translationViewModel.status === STATUS_READY) {
        Column() {
          Button($r('app.string.translate_retry'))
            .width('100%')
            .height($r('app.float.search_field_height'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_body'))
            .fontColor(themePalette.accent())
            .onClick(() => {
              translationViewModel.retry();
            })
        }
        .width('100%')
        .padding({ bottom: safeArea.bottomInsetVp / 2 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    .alignItems(HorizontalAlign.Start)
  }
}
