import { appSettings } from '../model/AppSettings';
import { notifyViewModel } from '../viewmodel/NotifyViewModel';
import { themePalette } from '../model/ThemePalette';

/** 授权状态只由父页持有；子组件通过 V2 事件上报操作。 */
@ComponentV2
export struct NotifyPermissionCard {
  @Param deniedOnce: boolean = false;
  @Param asking: boolean = false;
  @Event onRefresh: () => void = () => {};
  @Event onAsk: () => void = () => {};

  build() {
    Column({ space: $r('app.float.space_s') }) {
      Row({ space: $r('app.float.space_s') }) {
        SymbolGlyph(notifyViewModel.authorized ? $r('sys.symbol.bell') : $r('sys.symbol.bell_slash'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([notifyViewModel.authorized
            ? themePalette.accent()
            : $r('app.color.hm_text_secondary')])
        Text(notifyViewModel.authorized
          ? $r('app.string.notify_permission_on')
          : $r('app.string.notify_permission_off'))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .layoutWeight(1)
        if (!notifyViewModel.authorized) {
          if (this.deniedOnce) {
            // 已拒绝过一次：不再弹系统框，交给用户去系统设置开，回来点「重新检查」。
            Button($r('app.string.notify_permission_check'))
              .buttonStyle(ButtonStyleMode.TEXTUAL)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor(themePalette.accent())
              .onClick(() => {
                this.onRefresh();
              })
          } else {
            Button($r('app.string.notify_permission_grant'))
              .buttonStyle(ButtonStyleMode.NORMAL)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_on_brand'))
              .backgroundColor(themePalette.fill())
              .enabled(!this.asking)
              .onClick(() => {
                this.onAsk();
              })
          }
        }
      }
      .width('100%')

      if (!notifyViewModel.authorized) {
        Text($r('app.string.notify_permission_hint'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      } else if (!appSettings.notifyNewArticles) {
        Text($r('app.string.notify_status_off'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }
}
