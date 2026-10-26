/*
 * PrivacyView.ets — 隐私与数据页（NavDestination 内容，纯状态管理 V2）。
 *
 * 目的：把「哪些数据留在本机 / 哪些会外发 / 受哪些权限与开关控制」集中说清楚，
 * 并给出一键到达对应设置页与清空翻译缓存的入口。
 *
 * 页面只读 PrivacyViewModel + 事件上报；不在这里直接读数据库或发网络请求。
 */

import { common } from '@kit.AbilityKit';
import { privacyViewModel } from '../viewmodel/PrivacyViewModel';
import { safeArea } from '../service/SafeAreaController';
import { ToastUtil } from '../common/utils/ToastUtil';
import { RouterConstants } from '../common/constants/RouterConstants';

/** 带右侧状态的说明行：@Param 保证异步读到的状态更新后能刷新。 */
@ComponentV2
struct PrivacyStatusRow {
  @Param title: ResourceStr = '';
  @Param desc: ResourceStr = '';
  @Param status: ResourceStr = '';
  @Param statusOk: boolean = false;

  build() {
    Row({ space: $r('app.float.space_s') }) {
      Column({ space: $r('app.float.space_xxs') }) {
        Text(this.title)
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .width('100%')
        Text(this.desc)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.status)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor(this.statusOk ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary'))
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
export struct PrivacyView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context !== undefined) {
      privacyViewModel.refresh(context);
    }
  }

  private async clearCache(): Promise<void> {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    const cleared: number = await privacyViewModel.clearTranslationCache(context);
    ToastUtil.show(this.getUIContext(), $r('app.string.privacy_cache_cleared', cleared));
  }

  private go(page: string): void {
    this.navPathStack.pushPath(new NavPathInfo(page, ''));
  }

  @Builder
  SectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize($r('app.float.font_size_section'))
      .fontColor($r('app.color.hm_text_secondary'))
      .margin({
        top: $r('app.float.space_xl'),
        bottom: $r('app.float.space_s'),
        left: $r('app.float.space_xs')
      })
  }

  /** 说明行：标题 + 描述（无交互）。 */
  @Builder
  InfoRow(title: ResourceStr, desc: ResourceStr) {
    Column({ space: $r('app.float.space_xxs') }) {
      Text(title)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')
      Text(desc)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
    }
    .width('100%')
    .padding({
      left: $r('app.float.space_m'),
      right: $r('app.float.space_m'),
      top: $r('app.float.space_s'),
      bottom: $r('app.float.space_s')
    })
    .alignItems(HorizontalAlign.Start)
  }

  /** 可点击的设置入口行。 */
  @Builder
  NavRow(title: ResourceStr, page: string) {
    Row({ space: $r('app.float.space_s') }) {
      Text(title)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([$r('app.color.hm_text_secondary')])
    }
    .width('100%')
    .height($r('app.float.row_height'))
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    .onClick(() => {
      this.go(page);
    })
  }

  build() {
    List({ scroller: this.scroller }) {
      ListItem() {
        Column() {
          Row().width('100%').height(safeArea.contentTopInsetVp)

          Text($r('app.string.privacy_settings_desc'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .padding({ top: $r('app.float.space_s') })

          this.SectionTitle($r('app.string.privacy_section_local'))
          Column() {
            this.InfoRow($r('app.string.privacy_local_subscriptions_title'),
              $r('app.string.privacy_local_subscriptions_desc'))
            Divider().color($r('app.color.hm_divider'))
            this.InfoRow($r('app.string.privacy_local_reading_title'),
              $r('app.string.privacy_local_reading_desc'))
            Divider().color($r('app.color.hm_divider'))
            this.InfoRow($r('app.string.privacy_local_settings_title'),
              $r('app.string.privacy_local_settings_desc'))
          }
          .width('100%')
          .backgroundColor($r('app.color.hm_card_background'))
          .borderRadius($r('app.float.radius_card'))

          this.SectionTitle($r('app.string.privacy_section_outbound'))
          Column() {
            this.InfoRow($r('app.string.privacy_out_fetch_title'),
              $r('app.string.privacy_out_fetch_desc'))
            Divider().color($r('app.color.hm_divider'))
            PrivacyStatusRow({
              title: $r('app.string.privacy_out_remote_title'),
              desc: $r('app.string.privacy_out_remote_desc'),
              status: privacyViewModel.remoteHost.length > 0
                ? $r('app.string.privacy_remote_connected')
                : $r('app.string.privacy_remote_unknown'),
              statusOk: privacyViewModel.remoteConnected
            })
            Divider().color($r('app.color.hm_divider'))
            PrivacyStatusRow({
              title: $r('app.string.privacy_out_translate_title'),
              desc: $r('app.string.privacy_out_translate_desc'),
              status: privacyViewModel.translationOn
                ? $r('app.string.privacy_translation_on')
                : $r('app.string.privacy_translation_off'),
              statusOk: privacyViewModel.translationOn
            })
            Divider().color($r('app.color.hm_divider'))
            this.InfoRow($r('app.string.privacy_out_share_title'),
              $r('app.string.privacy_out_share_desc'))
            Divider().color($r('app.color.hm_divider'))
            this.InfoRow($r('app.string.privacy_out_backup_title'),
              $r('app.string.privacy_out_backup_desc'))
          }
          .width('100%')
          .backgroundColor($r('app.color.hm_card_background'))
          .borderRadius($r('app.float.radius_card'))

          Text($r('app.string.privacy_out_cross_border_desc'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })

          this.SectionTitle($r('app.string.privacy_section_permission'))
          Column() {
            PrivacyStatusRow({
              title: $r('app.string.privacy_perm_notification_title'),
              desc: $r('app.string.privacy_perm_notification_desc'),
              status: privacyViewModel.notificationOn
                ? $r('app.string.privacy_status_granted')
                : $r('app.string.privacy_status_denied'),
              statusOk: privacyViewModel.notificationOn
            })
            Divider().color($r('app.color.hm_divider'))
            this.InfoRow($r('app.string.privacy_perm_background_title'),
              $r('app.string.privacy_perm_background_desc'))
            Divider().color($r('app.color.hm_divider'))
            this.InfoRow($r('app.string.privacy_perm_media_title'),
              $r('app.string.privacy_perm_media_desc'))
            Divider().color($r('app.color.hm_divider'))
            PrivacyStatusRow({
              title: $r('app.string.privacy_perm_network_title'),
              desc: $r('app.string.privacy_perm_network_desc'),
              status: privacyViewModel.networkOnline
                ? $r('app.string.privacy_network_online')
                : $r('app.string.privacy_network_offline'),
              statusOk: privacyViewModel.networkOnline
            })
            Divider().color($r('app.color.hm_divider'))
            this.InfoRow($r('app.string.privacy_perm_files_title'),
              $r('app.string.privacy_perm_files_desc'))
            Divider().color($r('app.color.hm_divider'))
            this.InfoRow($r('app.string.privacy_perm_clipboard_title'),
              $r('app.string.privacy_perm_clipboard_desc'))
          }
          .width('100%')
          .backgroundColor($r('app.color.hm_card_background'))
          .borderRadius($r('app.float.radius_card'))

          this.SectionTitle($r('app.string.privacy_section_control'))
          Column() {
            Row() {
              Column({ space: $r('app.float.space_xxs') }) {
                Text($r('app.string.privacy_control_cache_title'))
                  .fontSize($r('app.float.font_size_body'))
                  .fontColor($r('app.color.hm_text_primary'))
                  .width('100%')
                Text($r('app.string.privacy_control_cache_desc', privacyViewModel.translationCacheCount))
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.hm_text_secondary'))
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Button($r('app.string.privacy_control_clear_cache'))
                .buttonStyle(ButtonStyleMode.TEXTUAL)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.hm_danger'))
                .enabled(!privacyViewModel.clearing)
                .onClick(() => {
                  this.clearCache();
                })
            }
            .width('100%')
            .padding({
              left: $r('app.float.space_m'),
              right: $r('app.float.space_m'),
              top: $r('app.float.space_s'),
              bottom: $r('app.float.space_s')
            })
            Divider().color($r('app.color.hm_divider'))
            this.NavRow($r('app.string.privacy_control_translate_entry'),
              RouterConstants.PAGE_TRANSLATE_SETTINGS)
            Divider().color($r('app.color.hm_divider'))
            this.NavRow($r('app.string.privacy_control_remote_entry'), RouterConstants.PAGE_REMOTE)
            Divider().color($r('app.color.hm_divider'))
            this.NavRow($r('app.string.privacy_control_backup_entry'), RouterConstants.PAGE_BACKUP)
          }
          .width('100%')
          .backgroundColor($r('app.color.hm_card_background'))
          .borderRadius($r('app.float.radius_card'))

          Text($r('app.string.privacy_footer_no_tracking'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .margin({ top: $r('app.float.space_m'), left: $r('app.float.space_xs') })

          Text($r('app.string.privacy_version'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })

          Blank().height(safeArea.contentBottomInsetVp)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
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
