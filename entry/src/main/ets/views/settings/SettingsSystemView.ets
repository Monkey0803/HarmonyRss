/*
 * SettingsSystemView.ets — 「系统与隐私」二级页（纯展示 + 事件上报）。
 *
 * 内容：智感握姿、防窥保护、远端服务、隐私与数据、诊断、分享与模板入口。
 * 都是「系统能力 / 数据出口」类设置，因此从主页收拢到这一页。
 */

import { common } from '@kit.AbilityKit';
import { settingsViewModel } from '../../viewmodel/SettingsViewModel';
import { antiPeep } from '../../service/AntiPeep';
import { RouterConstants } from '../../common/constants/RouterConstants';
import { safeArea } from '../../service/SafeAreaController';
import { NavSettingRow, SettingField, SettingsSectionTitle, SwitchSettingRow } from './SettingsRows';

@ComponentV2
export struct SettingsSystemView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  private hostContext(): common.UIAbilityContext {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    return context as common.UIAbilityContext;
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        // 透明标题栏占位：内容可以穿过标题栏下方。
        Row().width('100%').height(safeArea.contentTopInsetVp)

        SettingsSectionTitle({ title: $r('app.string.section_system') })
        Column() {
          SwitchSettingRow({
            icon: $r('sys.symbol.hand_raised_hexagon'),
            title: $r('app.string.row_grip'),
            field: SettingField.GRIP,
            onToggle: (value: boolean) => {
              settingsViewModel.setGripEnabled(value);
            }
          })
          Divider().color($r('app.color.hm_divider'))
          SwitchSettingRow({
            icon: $r('sys.symbol.eye_slash'),
            title: $r('app.string.row_antipeep'),
            field: SettingField.ANTI_PEEP,
            onToggle: (value: boolean) => {
              settingsViewModel.setAntiPeepEnabled(value, this.hostContext());
            }
          })
          Divider().color($r('app.color.hm_divider'))
          NavSettingRow({
            icon: $r('sys.symbol.link'),
            title: $r('app.string.remote_entry_title'),
            onOpen: () => {
              this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_REMOTE, ''));
            }
          })
          Divider().color($r('app.color.hm_divider'))
          // 云同步：第一批只接本机模拟后端，先打通同步链路。
          NavSettingRow({
            icon: $r('sys.symbol.icloud'),
            title: $r('app.string.sync_entry_title'),
            onOpen: () => {
              this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_SYNC, ''));
            }
          })
          Divider().color($r('app.color.hm_divider'))
          // 外发数据说明 / 权限状态 / 数据控制集中在一页。
          NavSettingRow({
            icon: $r('sys.symbol.lock'),
            title: $r('app.string.privacy_settings_title'),
            onOpen: () => {
              this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_PRIVACY, ''));
            }
          })
          Divider().color($r('app.color.hm_divider'))
          // 启动 / 抓取耗时、失败归类、上次退出原因与源健康（只写本机）。
          NavSettingRow({
            icon: $r('sys.symbol.exclamationmark_circle'),
            title: $r('app.string.diagnostics_entry'),
            onOpen: () => {
              this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_DIAGNOSTICS, ''));
            }
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        if (!antiPeep.supported) {
          Text($r('app.string.aux_antipeep_unsupported'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })
        }

        SettingsSectionTitle({ title: $r('app.string.section_share') })
        Column() {
          // 分享面板用到的模板管理集中在独立页面：面板本身只负责「用」，不负责「改」。
          NavSettingRow({
            icon: $r('sys.symbol.doc_text'),
            title: $r('app.string.share_settings_title'),
            onOpen: () => {
              this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_SHARE_SETTINGS, ''));
            }
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.hm_card_background'))
        .borderRadius($r('app.float.radius_card'))

        // 底部预留：避让系统导航条。
        Blank().height(safeArea.contentBottomInsetVp)
      }
      .width('100%')
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    // Scroll 默认把「内容比视口短」的内容整体居中，会让首屏顶部多出一条空白；
    // 这里固定从顶部开始排。
    .align(Alignment.TopStart)
    .clip(false)
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
