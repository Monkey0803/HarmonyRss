import { AppMenu } from '../common/components/AppMenu';
import { MenuItemSpec, MenuSpec } from '../common/components/MenuSpec';
import { MaterialController } from '../service/MaterialController';
import { appSettings } from '../model/AppSettings';

/**
 * 面板里的一行动作 / 目标。
 * 用 @ComponentV2 而不是多参 @Builder：busy / 置灰状态变化时整行要跟着刷新
 * （多参 @Builder 不参与动态刷新，见 ArkUI「@Builder 参数传递规则」）。
 */
@ComponentV2
export struct ShareRow {
  @Param label: ResourceStr = '';
  /** 是否展示右侧原因文案（置灰时）。 */
  @Param showReason: boolean = false;
  @Param reason: ResourceStr = '';
  @Param rowEnabled: boolean = true;
  @Event onTap: () => void = () => {
  };

  build() {
    Row({ space: $r('app.float.space_s') }) {
      Text(this.label)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.showReason) {
        Text(this.reason)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    // 置灰用整体透明度：颜色仍走资源，不额外引入一份「禁用色」。
    .opacity(this.rowEnabled ? 1 : 0.4)
    .onClick(() => {
      if (this.rowEnabled) {
        this.onTap();
      }
    })
  }
}

/**
 * 模板行：名称 + 内容预览。
 * 点按弹出「复制 / 系统分享」二选一（bindMenu），模板本身不可直接编辑（管理在设置页）。
 */
@ComponentV2
export struct ShareTemplateRow {
  @Param templateId: string = '';
  @Param name: string = '';
  @Param preview: string = '';
  @Param rowEnabled: boolean = true;
  @Event onCopy: (id: string) => void = () => {
  };
  @Event onShare: (id: string) => void = () => {
  };

  /** 模板行菜单：复制 / 系统分享（均为普通动作，无危险项）。 */
  @Builder
  TemplateMenu() {
    AppMenu(this.templateMenuSpec());
  }

  /** 菜单规格：顺序与动作和改造前一致。 */
  private templateMenuSpec(): MenuSpec {
    return MenuSpec.fromItems([
      new MenuItemSpec('copy', $r('app.string.tpl_copy'), (): void => {
        this.onCopy(this.templateId);
      }),
      new MenuItemSpec('share', $r('app.string.tpl_share'), (): void => {
        this.onShare(this.templateId);
      })
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
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([$r('app.color.hm_text_secondary')])
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    .opacity(this.rowEnabled ? 1 : 0.4)
    .enabled(this.rowEnabled)
    .bindMenu(this.TemplateMenu(), MaterialController.menuOptions({}, appSettings.immersiveOn))
  }
}
