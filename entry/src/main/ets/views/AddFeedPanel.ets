/*
 * AddFeedPanel.ets — 「添加订阅源」可复用面板（纯状态管理 V2）。
 *
 * 三处复用：悬浮页签栏的底部面板（Index）、订阅源页签顶部卡片（SubscriptionsView）、
 * 系统分享进入的 SharePage。内部承载两阶段交互：
 *   阶段一 输入：多行地址 + 粘贴 / 添加按钮；
 *   阶段二 预览：可改标题、选分组、看条数与最新几条，确认后才落库。
 * 单地址走「输入 → 预览 → 确认」，多地址走「批量添加」（共享同一分组）。
 */

import { FeedPreview, PreviewItem, BatchResult } from '../model/FeedPreview';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { FeedError } from '../common/constants/RssConstants';
import { FeedErrorText } from '../common/utils/FeedErrorText';
import { ToastUtil } from '../common/utils/ToastUtil';
import { UrlText } from '../common/utils/UrlText';
import { DateUtil } from '../common/utils/DateUtil';
import { clipboardService } from '../service/ClipboardService';
import { MaterialController } from '../service/MaterialController';
import { appSettings } from '../model/AppSettings';

@ComponentV2
export struct AddFeedPanel {
  /** 面板标题（默认「添加订阅源」；分享入口可传「添加到 RSS」）。 */
  @Param panelTitle: ResourceStr = $r('app.string.home_add_feed_title');
  /**
   * 是否在面板内画标题。
   * 订阅源页把标题上移成小节标题（与设置页同一套层级），这里传 false；
   * 分享页 / 底部面板保持默认 true，标题仍在面板内。
   */
  @Param showTitle: boolean = true;
  /** 初始输入（分享入口把解析出的地址传进来）；非空时优先于剪贴板预填。 */
  @Param initialText: string = '';
  /** 成功添加一项 / 一批后回调，宿主据此关闭面板或刷新。 */
  @Event onSubmitResult: (added: boolean) => void = () => {
  };

  @Local inputText: string = '';
  @Local submitting: boolean = false;
  /** 是否有待确认的预览（阶段二）。 */
  @Local hasPreview: boolean = false;
  /** 预览展示用的扁平常量（避免观察整棵 ParsedFeed）。 */
  @Local previewUrl: string = '';
  @Local previewCount: number = 0;
  @Local previewItems: PreviewItem[] = [];
  @Local previewDuplicate: string = '';
  /** 可编辑的标题草稿 / 分组草稿。 */
  @Local draftTitle: string = '';
  @Local draftGroup: string = '';
  /** 是否正在新建分组（就地输入）。 */
  @Local groupEdit: boolean = false;
  @Local draftNewGroup: string = '';
  /** 待确认的预览对象（普通字段，不参与观察；确认落库时复用其已解析结果）。 */
  private pending: FeedPreview | undefined = undefined;

  aboutToAppear(): void {
    if (this.initialText.length > 0) {
      this.inputText = this.initialText;
    }
  }

  /** 读剪贴板：仅在用户点击粘贴控件（已获得临时授权）后调用。 */
  private async fillFromClipboard(): Promise<void> {
    const text: string = await clipboardService.readText();
    const urls: string[] = UrlText.extractUrls(text);
    if (urls.length > 0) {
      this.inputText = urls.join('\n');
    } else {
      ToastUtil.show(this.getUIContext(), $r('app.string.err_empty_url'));
    }
  }

  private async submit(): Promise<void> {
    const urls: string[] = UrlText.splitUrlLines(this.inputText);
    if (urls.length === 0) {
      ToastUtil.show(this.getUIContext(), $r('app.string.err_empty_url'));
      return;
    }
    // 单地址：进入预览确认；多地址：批量添加。
    if (urls.length === 1) {
      this.submitting = true;
      const preview: FeedPreview | undefined = await feedViewModel.previewFeed(urls[0]);
      this.submitting = false;
      if (preview !== undefined) {
        this.pending = preview;
        this.hasPreview = true;
        this.draftTitle = preview.title;
        this.previewUrl = preview.siteUrl.length > 0 ? preview.siteUrl : preview.resolvedUrl;
        this.previewCount = preview.itemCount;
        this.previewItems = preview.latest;
        this.previewDuplicate = preview.duplicateSiteTitle;
      }
      return;
    }
    this.submitting = true;
    const result: BatchResult = await feedViewModel.addFeeds(this.inputText, this.draftGroup);
    this.submitting = false;
    ToastUtil.show(this.getUIContext(),
      $r('app.string.subs_batch_result', result.added, result.duplicate, result.failed));
    if (result.added > 0) {
      this.reset();
      this.onSubmitResult(true);
    }
  }

  private async confirm(): Promise<void> {
    const preview: FeedPreview | undefined = this.pending;
    if (preview === undefined) {
      return;
    }
    this.submitting = true;
    const ok: boolean = await feedViewModel.commitFeed(preview, this.draftTitle, this.draftGroup);
    this.submitting = false;
    if (ok) {
      this.reset();
      this.onSubmitResult(true);
    }
  }

  private cancelPreview(): void {
    this.pending = undefined;
    this.hasPreview = false;
    this.previewItems = [];
    this.groupEdit = false;
    this.draftNewGroup = '';
    feedViewModel.errorCode = FeedError.NONE;
  }

  private reset(): void {
    this.inputText = '';
    this.pending = undefined;
    this.hasPreview = false;
    this.previewItems = [];
    this.previewUrl = '';
    this.previewCount = 0;
    this.previewDuplicate = '';
    this.draftTitle = '';
    this.draftGroup = '';
    this.groupEdit = false;
    this.draftNewGroup = '';
  }

  /** 分组显示文案：草稿为空时显示「未分组」。 */
  private groupLabel(): ResourceStr {
    return this.draftGroup.length > 0 ? this.draftGroup : $r('app.string.group_ungrouped');
  }

  @Builder
  GroupMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.group_ungrouped') })
        .onClick(() => {
          this.draftGroup = '';
        })
      ForEach(feedViewModel.groupNames(), (name: string) => {
        MenuItem({ content: name })
          .onClick(() => {
            this.draftGroup = name;
          })
      }, (name: string) => name)
      MenuItem({ content: $r('app.string.group_new') })
        .onClick(() => {
          this.groupEdit = true;
        })
    }
    .radius($r('app.float.radius_card'))
  }

  /** 分组选择器：默认显示当前分组（点开菜单），或就地新建分组。 */
  @Builder
  GroupPicker() {
    if (this.groupEdit) {
      Row({ space: $r('app.float.space_s') }) {
        TextInput({ text: this.draftNewGroup, placeholder: $r('app.string.group_hint') })
          .type(InputType.Normal)
          .fontSize($r('app.float.font_size_body'))
          .layoutWeight(1)
          .onChange((value: string) => {
            this.draftNewGroup = value;
          })
        Button($r('app.string.dialog_save'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .onClick(() => {
            const name: string = this.draftNewGroup.trim();
            if (name.length > 0) {
              this.draftGroup = name;
            }
            this.groupEdit = false;
            this.draftNewGroup = '';
          })
      }
      .width('100%')
    } else {
      Row({ space: $r('app.float.space_xs') }) {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([$r('app.color.hm_brand')])
        Text(this.groupLabel())
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .flexShrink(1)
        // 明确「可展开」：与设置页取值胶囊同一个视觉语言。
        SymbolGlyph($r('sys.symbol.arrowtriangle_down_fill'))
          .fontSize($r('app.float.icon_size_tiny'))
          .fontColor([$r('app.color.hm_text_primary')])
          .flexShrink(0)
      }
      .height($r('app.float.value_chip_height'))
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
      // 原来用卡片底色，和白卡片同色 → 看起来只是普通文字，点不到。
      .backgroundColor($r('app.color.hm_value_chip_background'))
      .borderRadius($r('app.float.radius_chip'))
      .bindMenu(this.GroupMenu(), MaterialController.menuOptions({}, appSettings.immersiveOn))
    }
  }

  @Builder
  InputPhase() {
    Column({ space: $r('app.float.space_s') }) {
      TextArea({ text: this.inputText, placeholder: $r('app.string.subs_url_hint') })
        .fontSize($r('app.float.font_size_body'))
        .maxLines(4)
        .constraintSize({ minHeight: 64, maxHeight: 140 })
        .onChange((value: string) => {
          this.inputText = value;
        })
      Row({ space: $r('app.float.space_s') }) {
        // 安全控件：用户点击后临时获得剪贴板读取授权（无需 READ_PASTEBOARD 权限）。
        // 注意：安全控件样式受系统校验约束，不要设置透明度 / 负 padding / 遮挡。
        PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE,
          buttonType: ButtonType.Capsule })
          .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
            if (this.submitting) {
              return;
            }
            if (result !== PasteButtonOnClickResult.SUCCESS) {
              ToastUtil.show(this.getUIContext(), $r('app.string.subs_paste_denied'));
              return;
            }
            this.fillFromClipboard();
          })
        Blank()
        Button(this.submitting ? $r('app.string.subs_adding') : $r('app.string.subs_add'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .constraintSize({ minWidth: 88 })
          .enabled(!this.submitting)
          .onClick(() => {
            this.submit();
          })
      }
      .width('100%')
      // 粘贴（安全控件，高度由系统决定）与添加按钮同一基线，避免一高一矮。
      .alignItems(VerticalAlign.Center)

      // 分组：批量添加时整批落到这里选的分组；单地址时作为预览分组的默认值。
      this.GroupPicker()

      if (feedViewModel.errorCode !== FeedError.NONE) {
        Text(FeedErrorText.of(feedViewModel.errorCode))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  PreviewPhase() {
    Column({ space: $r('app.float.space_m') }) {
      Text($r('app.string.subs_preview_title'))
        .fontSize($r('app.float.font_size_section'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      // 标题可改写（留空则用 feed 自身标题）。
      TextInput({ text: this.draftTitle, placeholder: $r('app.string.subs_rename_hint') })
        .type(InputType.Normal)
        .fontSize($r('app.float.font_size_body'))
        .onChange((value: string) => {
          this.draftTitle = value;
        })

      Text(this.previewUrl)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      if (this.previewDuplicate.length > 0) {
        Text($r('app.string.subs_duplicate_site', this.previewDuplicate))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .width('100%')
      }

      this.GroupPicker()

      if (this.previewCount === 0) {
        Text($r('app.string.subs_preview_no_items'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
      } else {
        Text($r('app.string.subs_article_count', this.previewCount))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        Text($r('app.string.subs_preview_latest'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        ForEach(this.previewItems, (item: PreviewItem) => {
          Row({ space: $r('app.float.space_s') }) {
            Text(item.title.length > 0 ? item.title : $r('app.string.article_title'))
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.hm_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(DateUtil.format(item.publishedAt))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
          }
          .width('100%')
        }, (item: PreviewItem) => item.title + '|' + item.publishedAt.toString())
      }

      Row({ space: $r('app.float.space_s') }) {
        Button($r('app.string.dialog_cancel'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_secondary'))
          .enabled(!this.submitting)
          .onClick(() => {
            this.cancelPreview();
          })
        Blank()
        Button(this.submitting ? $r('app.string.subs_adding') : $r('app.string.subs_confirm'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .enabled(!this.submitting)
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: $r('app.float.space_m') }) {
      if (this.showTitle) {
        Text(this.panelTitle)
          .fontSize($r('app.float.font_size_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.hm_text_primary'))
          .width('100%')
      }

      if (this.hasPreview) {
        this.PreviewPhase()
      } else {
        this.InputPhase()
      }
    }
    .width('100%')
    .padding($r('app.float.space_l'))
    .alignItems(HorizontalAlign.Start)
  }
}
