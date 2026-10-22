/*
 * SmartFoldersView.ets — 智能文件夹管理页（NavDestination 内容，纯展示 + 事件上报）。
 *
 * 列表展示「名称 + 查询串摘要」，点一行即用同一套检索链路打开结果（见 SmartFolderViewModel.open）。
 * 支持新建 / 编辑 / 删除 / 上移下移；名称、查询串与数量上限的校验都在 validateSmartFolder（纯函数）。
 */

import { SmartFolder } from '../model/Tag';
import { smartFolderViewModel } from '../viewmodel/SmartFolderViewModel';
import { SmartFolderError, validateSmartFolder } from '../service/SmartFolderStore';
import { RouterConstants } from '../common/constants/RouterConstants';
import { MaterialController } from '../service/MaterialController';
import { appSettings } from '../model/AppSettings';
import { safeArea } from '../service/SafeAreaController';
import { ToastUtil } from '../common/utils/ToastUtil';

@ComponentV2
export struct SmartFoldersView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  /** 编辑器显隐（新建 / 编辑共用一块内联面板）。 */
  @Local editorOpen: boolean = false;
  /** 正在编辑的 id（空串 = 新建）。 */
  @Local editingId: string = '';
  @Local nameDraft: string = '';
  @Local queryDraft: string = '';
  /** 最近一次校验失败原因（空串 = 无错误）。 */
  @Local errorText: string = '';

  aboutToAppear(): void {
    smartFolderViewModel.load();
  }

  /** 校验错误 → 文案。 */
  private errorMessage(): ResourceStr {
    if (this.errorText === SmartFolderError.NAME_EMPTY || this.errorText === SmartFolderError.NAME_TOO_LONG) {
      return $r('app.string.smart_folder_name_invalid');
    }
    if (this.errorText === SmartFolderError.QUERY_TOO_LONG) {
      return $r('app.string.smart_folder_query_too_long');
    }
    if (this.errorText === SmartFolderError.LIMIT_REACHED) {
      return $r('app.string.smart_folder_limit_reached');
    }
    return $r('app.string.smart_folder_query_empty');
  }

  private startCreate(): void {
    this.editingId = '';
    this.nameDraft = '';
    this.queryDraft = '';
    this.errorText = '';
    this.editorOpen = true;
  }

  private startEdit(folder: SmartFolder): void {
    this.editingId = folder.id;
    this.nameDraft = folder.name;
    this.queryDraft = folder.query;
    this.errorText = '';
    this.editorOpen = true;
  }

  /** 保存（新建 / 编辑）：先本地校验给出具体原因，再落库。 */
  private async save(): Promise<void> {
    const isCreate: boolean = this.editingId.length === 0;
    const error: string = validateSmartFolder(this.nameDraft, this.queryDraft,
      smartFolderViewModel.folders.length, isCreate);
    if (error !== SmartFolderError.NONE) {
      this.errorText = error;
      return;
    }
    const ok: boolean = isCreate
      ? (await smartFolderViewModel.create(this.nameDraft, this.queryDraft)) !== undefined
      : await smartFolderViewModel.update(this.editingId, this.nameDraft, this.queryDraft);
    if (!ok) {
      this.errorText = smartFolderViewModel.lastError;
      return;
    }
    this.editorOpen = false;
    this.editingId = '';
    this.errorText = '';
  }

  /** 打开：写入 pendingQuery 后跳搜索页（校验失败说明记录已失效）。 */
  private openFolder(folder: SmartFolder): void {
    if (!smartFolderViewModel.open(folder)) {
      ToastUtil.show(this.getUIContext(), $r('app.string.smart_folder_open_failed'));
      return;
    }
    this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_SEARCH, ''));
  }

  /** 删除前确认：只删保存的查询。 */
  private confirmRemove(folder: SmartFolder): void {
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const removeButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.smart_folder_remove'),
      fontColor: $r('app.color.hm_danger'),
      action: () => {
        smartFolderViewModel.remove(folder.id);
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: folder.name,
      message: $r('app.string.smart_folder_remove_confirm_message'),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: removeButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  @Builder
  FolderMenu(folder: SmartFolder) {
    Menu() {
      MenuItem({ content: $r('app.string.smart_folder_edit') })
        .onClick(() => {
          this.startEdit(folder);
        })
      MenuItem({ content: $r('app.string.smart_folder_move_up') })
        .onClick(() => {
          smartFolderViewModel.move(folder.id, -1);
        })
      MenuItem({ content: $r('app.string.smart_folder_move_down') })
        .onClick(() => {
          smartFolderViewModel.move(folder.id, 1);
        })
      MenuItem({ content: $r('app.string.smart_folder_remove') })
        .contentFontColor($r('app.color.hm_danger'))
        .onClick(() => {
          this.confirmRemove(folder);
        })
    }
    .radius($r('app.float.radius_card'))
  }

  /** 新建 / 编辑面板。 */
  @Builder
  Editor() {
    Column({ space: $r('app.float.space_s') }) {
      Text(this.editingId.length === 0
        ? $r('app.string.smart_folder_new')
        : $r('app.string.smart_folder_edit'))
        .fontSize($r('app.float.font_size_section'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      TextInput({ text: this.nameDraft, placeholder: $r('app.string.smart_folder_name_hint') })
        .type(InputType.Normal)
        .fontSize($r('app.float.font_size_body'))
        .width('100%')
        .onChange((value: string) => {
          this.nameDraft = value;
          this.errorText = '';
        })

      TextInput({ text: this.queryDraft, placeholder: $r('app.string.smart_folder_query_hint') })
        .type(InputType.Normal)
        .fontSize($r('app.float.font_size_body'))
        .width('100%')
        .onChange((value: string) => {
          this.queryDraft = value;
          this.errorText = '';
        })

      Text($r('app.string.search_syntax_hint'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      if (this.errorText.length > 0) {
        Text(this.errorMessage())
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .width('100%')
      }

      Row({ space: $r('app.float.space_s') }) {
        Blank()
        Button($r('app.string.dialog_cancel'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .onClick(() => {
            this.editorOpen = false;
            this.editingId = '';
            this.errorText = '';
          })
        Button($r('app.string.smart_folder_save'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  FolderRow(folder: SmartFolder) {
    Row({ space: $r('app.float.space_m') }) {
      SymbolGlyph($r('sys.symbol.folder_fill'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([$r('app.color.hm_brand')])

      Column({ space: $r('app.float.space_xxs') }) {
        Text(folder.name)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(folder.query)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        this.openFolder(folder);
      })

      SymbolGlyph($r('sys.symbol.more'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([$r('app.color.hm_text_secondary')])
        .padding($r('app.float.space_xs'))
        .bindMenu(this.FolderMenu(folder), MaterialController.menuOptions({}, appSettings.immersiveOn))
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  @Builder
  Header() {
    Column({ space: $r('app.float.space_m') }) {
      Row().width('100%').height(safeArea.contentTopInsetVp)

      Row({ space: $r('app.float.space_s') }) {
        Column({ space: $r('app.float.space_xs') }) {
          Text($r('app.string.smart_folder_title'))
            .fontSize($r('app.float.font_size_section'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.hm_text_primary'))
          Text($r('app.string.smart_folder_entry', smartFolderViewModel.folders.length))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button($r('app.string.smart_folder_new'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .enabled(smartFolderViewModel.canCreate())
          .onClick(() => {
            this.startCreate();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.editorOpen) {
        this.Editor()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    List({ scroller: this.scroller }) {
      ListItem() {
        this.Header()
      }
      .margin({ bottom: $r('app.float.space_s') })

      if (smartFolderViewModel.loading && smartFolderViewModel.folders.length === 0) {
        ListItem() {
          Text($r('app.string.home_loading'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding($r('app.float.space_2xl'))
        }
      } else if (smartFolderViewModel.folders.length === 0) {
        ListItem() {
          Text($r('app.string.smart_folder_empty'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding($r('app.float.space_2xl'))
        }
      } else {
        ForEach(smartFolderViewModel.folders, (folder: SmartFolder) => {
          ListItem() {
            this.FolderRow(folder)
          }
          .margin({ bottom: $r('app.float.space_s') })
        }, (folder: SmartFolder) => folder.id + '_' + folder.name + '_' + folder.query + '_' + folder.sortOrder)
      }

      ListItem() {
        Row().width('100%').height(safeArea.bottomInsetVp)
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .clip(false)
    .cachedCount(3, true)
    .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
