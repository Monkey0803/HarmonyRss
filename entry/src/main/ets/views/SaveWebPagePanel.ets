/* 独立网页稍后读：输入 / 分享地址 → 联网预览 → 用户确认保存。 */
import { WebPagePreview } from '../model/WebPagePreview';
import { webPageSaveService, normalizeWebPageUrl } from '../service/WebPageSaveService';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { UrlText } from '../common/utils/UrlText';
import { clipboardService } from '../service/ClipboardService';
import { Toast } from '@monkey0803/toast-kit';
import { themePalette } from '../model/ThemePalette';

@ComponentV2
export struct SaveWebPagePanel {
  @Param initialText: string = '';
  /**
   * 是否在面板内画标题。
   * 底部面板 / 分享页把标题上移成模式胶囊（「保存网页」已经在胶囊上），这里传 false；
   * 独立页面内嵌时保持默认 true。
   */
  @Param showTitle: boolean = true;
  /** 是否在标题行右侧画关闭图标（仅 showTitle 为 true 时可见）。 */
  @Param showClose: boolean = false;
  @Event onClose: () => void = () => {};
  @Event onSaved: (articleId: string) => void = () => {};

  @Local inputText: string = '';
  @Local loading: boolean = false;
  @Local previewTitle: string = '';
  @Local previewSource: string = '';
  @Local previewSummary: string = '';
  @Local previewUrl: string = '';
  @Local hasOfflineBody: boolean = false;
  private pending: WebPagePreview | undefined = undefined;

  aboutToAppear(): void {
    const urls: string[] = UrlText.extractUrls(this.initialText);
    this.inputText = urls.length > 0 ? urls[0] : this.initialText;
  }

  @Monitor('initialText')
  onSharedTextChange(): void {
    const urls: string[] = UrlText.extractUrls(this.initialText);
    this.inputText = urls.length > 0 ? urls[0] : this.initialText;
    this.clearPreview();
  }

  private async paste(): Promise<void> {
    const text: string = await clipboardService.readText();
    const urls: string[] = UrlText.extractUrls(text);
    if (urls.length > 0) {
      this.inputText = urls[0];
      this.clearPreview();
    } else {
      Toast.show($r('app.string.save_web_invalid_url'));
    }
  }

  private clearPreview(): void {
    this.pending = undefined;
    this.previewTitle = '';
    this.previewSource = '';
    this.previewSummary = '';
    this.previewUrl = '';
    this.hasOfflineBody = false;
  }

  private async preview(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.clearPreview();
    if (normalizeWebPageUrl(this.inputText).length === 0) {
      Toast.show($r('app.string.save_web_invalid_url'));
      return;
    }
    this.loading = true;
    try {
      const result: WebPagePreview | undefined = await webPageSaveService.preview(this.inputText);
      if (result === undefined) {
        Toast.show($r('app.string.save_web_invalid_url'));
        return;
      }
      this.pending = result;
      this.previewTitle = result.title;
      this.previewSource = result.source;
      this.previewSummary = result.summary;
      this.previewUrl = result.url;
      this.hasOfflineBody = result.readerHtml.length > 0;
    } catch (err) {
      Toast.show($r('app.string.save_web_fetch_failed'));
    } finally {
      this.loading = false;
    }
  }

  private async save(): Promise<void> {
    const preview: WebPagePreview | undefined = this.pending;
    if (this.loading || preview === undefined) {
      return;
    }
    this.loading = true;
    try {
      const result = await feedViewModel.saveWebPage(preview);
      if (result === undefined) {
        Toast.show($r('app.string.save_web_save_failed'));
        return;
      }
      Toast.show($r('app.string.save_web_saved'));
      this.clearPreview();
      this.onSaved(result.articleId);
    } catch (err) {
      Toast.show($r('app.string.save_web_save_failed'));
    } finally {
      this.loading = false;
    }
  }

  build() {
    Column({ space: $r('app.float.space_m') }) {
      if (this.showTitle) {
        Row({ space: $r('app.float.space_s') }) {
          Text($r('app.string.save_web_title'))
            .fontSize($r('app.float.font_size_section'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.hm_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.showClose) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize($r('app.float.icon_size'))
              .fontColor([themePalette.accent()])
              .padding($r('app.float.space_xs'))
              .accessibilityText($r('app.string.dialog_cancel'))
              .onClick(() => { this.onClose(); })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      TextInput({ text: this.inputText, placeholder: $r('app.string.save_web_hint') })
        .type(InputType.URL)
        .fontSize($r('app.float.font_size_body'))
        .height(44)
        .onChange((value: string) => {
          this.inputText = value;
          this.clearPreview();
        })

      Row({ space: $r('app.float.space_s') }) {
        PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE,
          buttonType: ButtonType.Capsule })
          .fontColor($r('app.color.hm_on_brand'))
          .iconColor($r('app.color.hm_on_brand'))
          .backgroundColor(themePalette.fill())
          .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
            if (result === PasteButtonOnClickResult.SUCCESS && !this.loading) {
              this.paste();
            } else if (result !== PasteButtonOnClickResult.SUCCESS) {
              Toast.show($r('app.string.subs_paste_denied'));
            }
          })
        Blank()
        Button(this.loading ? $r('app.string.save_web_loading') : $r('app.string.save_web_preview'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor(themePalette.fill())
          .enabled(!this.loading)
          .onClick(() => { this.preview(); })
      }
      .width('100%')

      if (this.previewTitle.length > 0) {
        Text(this.previewTitle)
          .fontSize($r('app.float.font_size_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hm_text_primary'))
          .maxLines(2)
        Text(this.previewSource + ' · ' + this.previewUrl)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.previewSummary.length > 0) {
          Text(this.previewSummary)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .maxLines(3)
        }
        if (!this.hasOfflineBody) {
          Text($r('app.string.save_web_no_reader'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
        Button($r('app.string.save_web_confirm'))
          .width('100%')
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor(themePalette.fill())
          .enabled(!this.loading)
          .onClick(() => { this.save(); })
      }
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .alignItems(HorizontalAlign.Start)
  }
}
