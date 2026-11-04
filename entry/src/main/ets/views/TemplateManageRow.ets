import { AppMenu } from '../common/components/AppMenu';
import { MenuItemSpec, MenuSpec } from '../common/components/MenuSpec';
import { appSettings } from '../model/AppSettings';
import { MaterialController } from '../service/MaterialController';

/** 模板管理行：名称 + 内容摘要 + 「更多」菜单。 */
@ComponentV2
export struct TemplateManageRow {
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

  /** 行菜单：编辑 / 上移 / 下移 / 删除（删除为危险动作，由上层走二次确认）。 */
  @Builder
  RowMenu() {
    AppMenu(this.rowMenuSpec());
  }

  /** 菜单规格：顺序与动作和改造前一致。 */
  private rowMenuSpec(): MenuSpec {
    return MenuSpec.fromItems([
      new MenuItemSpec('edit', $r('app.string.tpl_edit'), (): void => {
        this.onEdit(this.templateId);
      }),
      new MenuItemSpec('move_up', $r('app.string.tpl_move_up'), (): void => {
        this.onMoveUp(this.templateId);
      }),
      new MenuItemSpec('move_down', $r('app.string.tpl_move_down'), (): void => {
        this.onMoveDown(this.templateId);
      }),
      new MenuItemSpec('delete', $r('app.string.tpl_delete'), (): void => {
        this.onDelete(this.templateId);
      }).markDanger()
    ]);
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
