/*
 * TagsView.ets — 标签管理页（NavDestination 内容，纯展示 + 事件上报）。
 *
 * 上半部分是新建标签，下面列出全部标签（名称 + 文章数 + 选中态）。
 * 多选为 AND 语义：只有同时具备所选全部标签的文章才会出现在「查看结果」里。
 * 行菜单支持重命名 / 删除（删除需确认，文章本身不受影响）。
 */

import { TagWithCount } from '../model/Tag';
import { tagViewModel } from '../viewmodel/TagViewModel';
import { RouterConstants } from '../common/constants/RouterConstants';
import { MaterialController } from '../service/MaterialController';
import { appSettings } from '../model/AppSettings';
import { safeArea } from '../service/SafeAreaController';
import { ToastUtil } from '../common/utils/ToastUtil';

@ComponentV2
export struct TagsView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  /** 新建标签的输入草稿。 */
  @Local draftName: string = '';
  /** 就地重命名：正在编辑的标签 id 与草稿名。 */
  @Local renameId: string = '';
  @Local renameDraft: string = '';
  @Local busy: boolean = false;

  aboutToAppear(): void {
    tagViewModel.load();
  }

  private isSelected(id: string): boolean {
    return tagViewModel.selectedTagIds.indexOf(id) >= 0;
  }

  /** 新建标签（空名给提示，超上限 / 去重由 ViewModel 处理）。 */
  private async createTag(): Promise<void> {
    const name: string = this.draftName.trim();
    if (name.length === 0) {
      ToastUtil.show(this.getUIContext(), $r('app.string.tag_name_invalid'));
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    const created: TagWithCount | undefined = await tagViewModel.create(name);
    this.busy = false;
    if (created === undefined) {
      ToastUtil.show(this.getUIContext(), $r('app.string.tag_limit_reached'));
      return;
    }
    this.draftName = '';
  }

  /** 保存重命名（失败多半是与已有标签重名）。 */
  private async saveRename(id: string): Promise<void> {
    const ok: boolean = await tagViewModel.rename(id, this.renameDraft);
    if (!ok) {
      ToastUtil.show(this.getUIContext(), $r('app.string.tag_action_failed'));
      return;
    }
    this.renameId = '';
    this.renameDraft = '';
  }

  /** 删除前确认：标签消失、文章保留。 */
  private confirmRemove(tag: TagWithCount): void {
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const removeButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.tag_remove'),
      fontColor: $r('app.color.hm_danger'),
      action: () => {
        tagViewModel.remove(tag.id);
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: tag.name,
      message: $r('app.string.tag_remove_confirm_message'),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: removeButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  /** 进入标签文章页：先按多标签 AND 拉第一页，再 push（失败也给明确提示）。 */
  private async openResults(): Promise<void> {
    const ids: string[] = tagViewModel.selectedTagIds;
    if (ids.length === 0) {
      ToastUtil.show(this.getUIContext(), $r('app.string.tag_select_hint'));
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    await tagViewModel.loadArticles(ids);
    this.busy = false;
    this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_TAG_ARTICLES, ''));
  }

  @Builder
  TagMenu(tag: TagWithCount) {
    Menu() {
      MenuItem({ content: $r('app.string.tag_rename') })
        .onClick(() => {
          this.renameId = tag.id;
          this.renameDraft = tag.name;
        })
      MenuItem({ content: $r('app.string.tag_remove') })
        .contentFontColor($r('app.color.hm_danger'))
        .onClick(() => {
          this.confirmRemove(tag);
        })
    }
    .radius($r('app.float.radius_card'))
  }

  @Builder
  TagRow(tag: TagWithCount) {
    Row({ space: $r('app.float.space_m') }) {
      SymbolGlyph(this.isSelected(tag.id) ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.circle'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([this.isSelected(tag.id) ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])

      if (this.renameId === tag.id) {
        TextInput({ text: this.renameDraft, placeholder: $r('app.string.tag_rename_hint') })
          .type(InputType.Normal)
          .fontSize($r('app.float.font_size_body'))
          .layoutWeight(1)
          .onChange((value: string) => {
            this.renameDraft = value;
          })
        Text($r('app.string.dialog_save'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .padding($r('app.float.space_s'))
          .onClick(() => {
            this.saveRename(tag.id);
          })
        Text($r('app.string.dialog_cancel'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .padding($r('app.float.space_s'))
          .onClick(() => {
            this.renameId = '';
          })
      } else {
        Column({ space: $r('app.float.space_xxs') }) {
          Text(tag.name)
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text($r('app.string.subs_article_count', tag.count))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        SymbolGlyph($r('sys.symbol.more'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .accessibilityText($r('app.string.action_more'))
          .padding($r('app.float.space_xs'))
          .bindMenu(this.TagMenu(tag), MaterialController.menuOptions({}, appSettings.immersiveOn))
      }
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor(this.isSelected(tag.id)
      ? $r('app.color.hm_menu_item_selected')
      : $r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .onClick(() => {
      if (this.renameId !== tag.id) {
        tagViewModel.toggleSelect(tag.id);
      }
    })
  }

  build() {
    Column({ space: $r('app.float.space_m') }) {
      // 透明标题栏占位
      Row().width('100%').height(safeArea.contentTopInsetVp)

      Row({ space: $r('app.float.space_s') }) {
        TextInput({ text: this.draftName, placeholder: $r('app.string.tag_new_hint') })
          .type(InputType.Normal)
          .fontSize($r('app.float.font_size_body'))
          .layoutWeight(1)
          .onChange((value: string) => {
            this.draftName = value;
          })
          .onSubmit(() => {
            this.createTag();
          })
        Button($r('app.string.tag_new'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .enabled(!this.busy)
          .onClick(() => {
            this.createTag();
          })
      }
      .width('100%')

      Text($r('app.string.tag_manage_hint'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      if (tagViewModel.tags.length === 0) {
        Text(tagViewModel.loading ? $r('app.string.home_loading') : $r('app.string.tag_empty'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .layoutWeight(1)
          .padding($r('app.float.space_2xl'))
      } else {
        List({ scroller: this.scroller }) {
          ForEach(tagViewModel.tags, (tag: TagWithCount) => {
            ListItem() {
              this.TagRow(tag)
            }
            .margin({ bottom: $r('app.float.space_s') })
          }, (tag: TagWithCount) => tag.id + '_' + tag.name + '_' + tag.count + '_' +
            (this.isSelected(tag.id) ? '1' : '0') + '_' + (this.renameId === tag.id ? 'e' : ''))
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ bottom: safeArea.contentBottomInsetVp })
      }

      if (tagViewModel.selectedTagIds.length > 0) {
        Row({ space: $r('app.float.space_xs') }) {
          Text($r('app.string.tag_view_results'))
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_on_brand'))
          Text('(' + tagViewModel.selectedTagIds.length + ')')
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_on_brand'))
        }
        .width('100%')
        .height($r('app.float.row_height'))
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.hm_brand'))
        .borderRadius($r('app.float.radius_card'))
        .enabled(!this.busy)
        .onClick(() => {
          this.openResults();
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding($r('app.float.space_l'))
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
