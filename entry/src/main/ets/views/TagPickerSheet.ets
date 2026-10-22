/*
 * TagPickerSheet.ets — 标签选择器（详情页「+」与首页批量打标共用）。
 *
 * 纯 V2 组件，可直接作为 bindSheet 的内容：
 *   TagPickerSheet({ selectedTagIds: [...], onConfirm: (ids) => { ... } })
 *
 * 交互：勾选已有标签 + 可直接新建（新建成功后自动选中），确认回传选中的标签 id 列表。
 * 只做展示与事件上报；读写、归一、去重、上限都在 TagViewModel / TagStore。
 */

import { TagWithCount } from '../model/Tag';
import { tagViewModel } from '../viewmodel/TagViewModel';
import { ToastUtil } from '../common/utils/ToastUtil';

@ComponentV2
export struct TagPickerSheet {
  /** 打开时的已选标签（详情页 = 本文标签；批量 = 空）。 */
  @Param selectedTagIds: string[] = [];
  /** 确认回调：回传最终选中的标签 id 列表。 */
  @Event onConfirm: (ids: string[]) => void = () => {};

  /** 面板内的临时选中态（确认前不写库）。 */
  @Local working: string[] = [];
  /** 新建标签的输入草稿。 */
  @Local draftName: string = '';
  @Local busy: boolean = false;

  aboutToAppear(): void {
    this.working = this.selectedTagIds.slice();
    tagViewModel.load();
  }

  /** 父级换了目标（例如连续对另一篇打标）时重新同步选中态。 */
  @Monitor('selectedTagIds')
  onSelectedChange(): void {
    this.working = this.selectedTagIds.slice();
  }

  private isPicked(id: string): boolean {
    return this.working.indexOf(id) >= 0;
  }

  private toggle(id: string): void {
    if (this.isPicked(id)) {
      this.working = this.working.filter((item: string) => item !== id);
    } else {
      this.working = this.working.concat([id]);
    }
  }

  /** 新建标签：成功即自动勾选（归一 / 去重 / 上限由 Store 负责）。 */
  private async createTag(): Promise<void> {
    if (this.busy) {
      return;
    }
    const name: string = this.draftName.trim();
    if (name.length === 0) {
      ToastUtil.show(this.getUIContext(), $r('app.string.tag_name_invalid'));
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
    if (!this.isPicked(created.id)) {
      this.working = this.working.concat([created.id]);
    }
  }

  @Builder
  TagRow(tag: TagWithCount) {
    Row({ space: $r('app.float.space_m') }) {
      SymbolGlyph(this.isPicked(tag.id) ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.circle'))
        .fontSize($r('app.float.icon_size'))
        .fontColor([this.isPicked(tag.id) ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary')])
      Text(tag.name)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text($r('app.string.subs_article_count', tag.count))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor(this.isPicked(tag.id)
      ? $r('app.color.hm_menu_item_selected')
      : $r('app.color.hm_value_chip_background'))
    .borderRadius($r('app.float.radius_card'))
    .onClick(() => {
      this.toggle(tag.id);
    })
  }

  build() {
    Column({ space: $r('app.float.space_m') }) {
      Text($r('app.string.tag_picker_title'))
        .fontSize($r('app.float.font_size_section'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')

      if (tagViewModel.tags.length === 0) {
        Text($r('app.string.tag_picker_empty'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
          .padding({ top: $r('app.float.space_m'), bottom: $r('app.float.space_m') })
      } else {
        List({ space: 8 }) {
          ForEach(tagViewModel.tags, (tag: TagWithCount) => {
            ListItem() {
              this.TagRow(tag)
            }
          }, (tag: TagWithCount) => tag.id + '_' + tag.name + '_' + tag.count + '_' + this.isPicked(tag.id))
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }

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

      Row() {
        Blank()
        Button($r('app.string.tag_apply'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .onClick(() => {
            this.onConfirm(this.working.slice());
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding($r('app.float.space_l'))
    .alignItems(HorizontalAlign.Start)
  }
}
