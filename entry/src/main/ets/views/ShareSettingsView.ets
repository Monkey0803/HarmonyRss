/*
 * ShareSettingsView.ets — 分享与模板管理页（NavDestination 内容，纯状态管理 V2）。
 *
 * 只做展示与事件上报：模板 CRUD / 排序 / 校验都在 ShareTemplates（纯逻辑 + 偏好库），
 * 页面通过 ShareViewModel.init / reloadTemplates 拿到最新列表。
 *
 * 交互约定：
 *   - 列表行右侧「更多」菜单里放 编辑 / 上移 / 下移 / 删除；删除走二次确认对话框。
 *   - 新建 / 编辑用页内表单（不用半模态）：表单有名称、多行内容、占位符说明与校验提示，
 *     半模态高度不够，键盘弹起时也更容易顶掉内容。
 *   - 默认模板是「首次使用未落库」的虚拟项，只读：不给编辑 / 删除入口，避免写库失败。
 */

import { common } from '@kit.AbilityKit';
import { ShareTemplate } from '../model/Share';
import { shareTemplates, validate } from '../service/ShareTemplates';
import { shareViewModel } from '../viewmodel/ShareViewModel';
import { CommonConstants } from '../common/constants/CommonConstants';
import { ToastUtil } from '../common/utils/ToastUtil';
import { safeArea } from '../service/SafeAreaController';
import { appSettings } from '../model/AppSettings';
import { MaterialController } from '../service/MaterialController';

/** 默认模板 id（与 ShareTemplates 内的虚拟默认模板一致；它不是落库数据，因此只读）。 */
const DEFAULT_TEMPLATE_ID: string = 'tpl_default';

/** 模板管理行：名称 + 内容摘要 + 「更多」菜单。 */
@ComponentV2
struct TemplateManageRow {
  @Param templateId: string = '';
  @Param name: string = '';
  @Param preview: string = '';
  /** 默认模板：只读（不显示菜单）。 */
  @Param readOnly: boolean = false;
  @Param rowEnabled: boolean = true;
  @Event onEdit: (id: string) => void = () => {
  };
  @Event onMoveUp: (id: string) => void = () => {
  };
  @Event onMoveDown: (id: string) => void = () => {
  };
  @Event onDelete: (id: string) => void = () => {
  };

  @Builder
  RowMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.tpl_edit') })
        .onClick(() => {
          this.onEdit(this.templateId);
        })
      MenuItem({ content: $r('app.string.tpl_move_up') })
        .onClick(() => {
          this.onMoveUp(this.templateId);
        })
      MenuItem({ content: $r('app.string.tpl_move_down') })
        .onClick(() => {
          this.onMoveDown(this.templateId);
        })
      MenuItem({ content: $r('app.string.tpl_delete') })
        .onClick(() => {
          this.onDelete(this.templateId);
        })
    }
    .radius($r('app.float.radius_card'))
  }

  build() {
    Row({ space: $r('app.float.space_s') }) {
      Column({ space: $r('app.float.space_xxs') }) {
        Text(this.name)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.preview)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.readOnly) {
          Text($r('app.string.tpl_default_hint'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (!this.readOnly) {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .padding($r('app.float.space_xs'))
          .accessibilityText($r('app.string.tpl_edit'))
          .enabled(this.rowEnabled)
          .bindMenu(this.RowMenu(), MaterialController.menuOptions({}, appSettings.immersiveOn))
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_m'),
      right: $r('app.float.space_m'),
      top: $r('app.float.space_s'),
      bottom: $r('app.float.space_s')
    })
  }
}

@ComponentV2
export struct ShareSettingsView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  /** 编辑器是否展开；editingId 为空表示「新建」。 */
  @Local editorOpen: boolean = false;
  @Local editingId: string = '';
  @Local draftName: string = '';
  @Local draftContent: string = '';
  /** 校验 / 落库失败的资源 key（空串 = 无错误）。 */
  @Local errorKey: string = '';
  @Local saving: boolean = false;

  aboutToAppear(): void {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context !== undefined) {
      shareViewModel.init(context as common.UIAbilityContext).then(() => {
      });
    }
  }

  private isDefault(template: ShareTemplate): boolean {
    return template.id === DEFAULT_TEMPLATE_ID;
  }

  /** 错误 key → 文案。 */
  private errorMessage(): ResourceStr {
    if (this.errorKey === 'tpl_err_name_empty') {
      return $r('app.string.tpl_err_name_empty');
    }
    if (this.errorKey === 'tpl_err_name_long') {
      return $r('app.string.tpl_err_name_long');
    }
    if (this.errorKey === 'tpl_err_content_empty') {
      return $r('app.string.tpl_err_content_empty');
    }
    if (this.errorKey === 'tpl_err_content_long') {
      return $r('app.string.tpl_err_content_long');
    }
    if (this.errorKey === 'tpl_err_max') {
      return $r('app.string.tpl_err_max');
    }
    return $r('app.string.tpl_err_save_failed');
  }

  /** 内容摘要：压成一行（多行内容在列表里最多显示两行）。 */
  private previewOf(content: string): string {
    return content.replace(/\s+/g, ' ').trim();
  }

  private startCreate(): void {
    this.errorKey = '';
    if (shareViewModel.templates.length >= CommonConstants.SHARE_TEMPLATE_MAX) {
      this.errorKey = 'tpl_err_max';
      ToastUtil.show(this.getUIContext(), $r('app.string.tpl_err_max'));
      return;
    }
    this.editingId = '';
    this.draftName = '';
    this.draftContent = '';
    this.editorOpen = true;
    this.scroller.scrollEdge(Edge.Top);
  }

  private startEdit(id: string): void {
    for (let i = 0; i < shareViewModel.templates.length; i += 1) {
      const template: ShareTemplate = shareViewModel.templates[i];
      if (template.id === id) {
        this.errorKey = '';
        this.editingId = template.id;
        this.draftName = template.name;
        this.draftContent = template.content;
        this.editorOpen = true;
        this.scroller.scrollEdge(Edge.Top);
        return;
      }
    }
  }

  private closeEditor(): void {
    this.editorOpen = false;
    this.editingId = '';
    this.draftName = '';
    this.draftContent = '';
    this.errorKey = '';
  }

  /** 保存：先本地校验（错误即时展示），再落库；成功刷新列表并收起表单。 */
  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    const error: string = validate(this.draftName, this.draftContent);
    if (error.length > 0) {
      this.errorKey = error;
      return;
    }
    this.saving = true;
    let ok: boolean = false;
    if (this.editingId.length === 0) {
      const created: ShareTemplate | undefined = await shareTemplates.create(this.draftName, this.draftContent);
      ok = created !== undefined;
    } else {
      ok = await shareTemplates.update(this.editingId, this.draftName, this.draftContent);
    }
    // 无论成功与否都刷新一次：失败时也不该让列表停在旧快照上。
    await shareViewModel.reloadTemplates();
    this.saving = false;
    if (!ok) {
      this.errorKey = this.editingId.length === 0 ? 'tpl_err_max' : 'tpl_err_save_failed';
      return;
    }
    this.closeEditor();
    ToastUtil.show(this.getUIContext(), $r('app.string.tpl_toast_saved'));
  }

  /** 删除（二次确认）：确认后落库并刷新。 */
  private confirmDelete(id: string): void {
    let name: string = '';
    for (let i = 0; i < shareViewModel.templates.length; i += 1) {
      if (shareViewModel.templates[i].id === id) {
        name = shareViewModel.templates[i].name;
        break;
      }
    }
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const confirmButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.tpl_delete'),
      fontColor: $r('app.color.hm_danger'),
      action: () => {
        this.remove(id);
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.tpl_delete'),
      message: $r('app.string.tpl_delete_confirm_named', name),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: confirmButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  private async remove(id: string): Promise<void> {
    const ok: boolean = await shareTemplates.remove(id);
    await shareViewModel.reloadTemplates();
    if (ok) {
      ToastUtil.show(this.getUIContext(), $r('app.string.tpl_toast_deleted'));
    } else {
      ToastUtil.show(this.getUIContext(), $r('app.string.tpl_err_save_failed'));
    }
  }

  /** 上移 / 下移：越界不报错，只是顺序不变。 */
  private async move(id: string, delta: number): Promise<void> {
    await shareTemplates.move(id, delta);
    await shareViewModel.reloadTemplates();
  }

  @Builder
  SectionLabel(label: ResourceStr) {
    Text(label)
      .fontSize($r('app.float.font_size_caption'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.hm_text_secondary'))
      .width('100%')
  }

  /** 新建 / 编辑表单。 */
  @Builder
  Editor() {
    Column({ space: $r('app.float.space_s') }) {
      Text(this.editingId.length === 0
        ? $r('app.string.tpl_new')
        : $r('app.string.tpl_edit'))
        .fontSize($r('app.float.font_size_section'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      this.SectionLabel($r('app.string.tpl_name_label'))
      TextInput({ text: this.draftName, placeholder: $r('app.string.tpl_name_hint') })
        .type(InputType.Normal)
        .maxLength(CommonConstants.SHARE_TEMPLATE_NAME_MAX)
        .fontSize($r('app.float.font_size_body'))
        .width('100%')
        .onChange((value: string) => {
          this.draftName = value;
          this.errorKey = '';
        })

      this.SectionLabel($r('app.string.tpl_content_label'))
      TextArea({ text: this.draftContent, placeholder: $r('app.string.tpl_content_hint') })
        .fontSize($r('app.float.font_size_body'))
        .maxLength(CommonConstants.SHARE_TEMPLATE_CONTENT_MAX)
        .maxLines(6)
        .constraintSize({ minHeight: 96, maxHeight: 200 })
        .width('100%')
        .onChange((value: string) => {
          this.draftContent = value;
          this.errorKey = '';
        })

      Text($r('app.string.tpl_placeholder_help'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      if (this.errorKey.length > 0) {
        Text(this.errorMessage())
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .width('100%')
      }

      Row({ space: $r('app.float.space_s') }) {
        Blank()
        Button($r('app.string.tpl_cancel'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .enabled(!this.saving)
          .onClick(() => {
            this.closeEditor();
          })
        Button($r('app.string.tpl_save'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .enabled(!this.saving)
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

  /** 模板列表（默认模板只读）。 */
  @Builder
  TemplateList() {
    Column() {
      if (shareViewModel.templates.length === 0) {
        Text($r('app.string.tpl_empty'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .padding($r('app.float.space_m'))
      } else {
        ForEach(shareViewModel.templates, (template: ShareTemplate, index: number) => {
          if (index > 0) {
            Divider().color($r('app.color.hm_divider'))
          }
          TemplateManageRow({
            templateId: template.id,
            name: template.name,
            preview: this.previewOf(template.content),
            readOnly: this.isDefault(template),
            rowEnabled: !this.saving,
            onEdit: (id: string) => {
              this.startEdit(id);
            },
            onMoveUp: (id: string) => {
              this.move(id, -1);
            },
            onMoveDown: (id: string) => {
              this.move(id, 1);
            },
            onDelete: (id: string) => {
              this.confirmDelete(id);
            }
          })
        }, (template: ShareTemplate) => template.id)
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  build() {
    List({ scroller: this.scroller }) {
      ListItem() {
        Column({ space: $r('app.float.space_m') }) {
          // 透明标题栏占位：内容可以穿过标题栏下方。
          Row().width('100%').height(safeArea.contentTopInsetVp)

          Row() {
            Text($r('app.string.tpl_section_title'))
              .fontSize($r('app.float.font_size_section'))
              .fontColor($r('app.color.hm_text_secondary'))
              .layoutWeight(1)
            Button($r('app.string.tpl_new'))
              .buttonStyle(ButtonStyleMode.TEXTUAL)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_brand'))
              .enabled(!this.saving)
              .onClick(() => {
                this.startCreate();
              })
          }
          .width('100%')

          if (this.editorOpen) {
            this.Editor()
          }

          this.TemplateList()

          Text($r('app.string.tpl_limit_hint'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')

          if (!this.editorOpen) {
            Text($r('app.string.tpl_placeholder_help'))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
              .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      ListItem() {
        Row().width('100%').height(safeArea.bottomInsetVp)
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .clip(false)
    .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
