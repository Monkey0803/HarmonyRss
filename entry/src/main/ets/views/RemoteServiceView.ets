/*
 * RemoteServiceView.ets — 「账号与服务」页（纯展示 + 事件上报）。
 *
 * 表单：服务地址 / 用户名 / 密码 / 允许明文 HTTP；连接后展示同步状态、立即同步与退出登录。
 * 业务逻辑全部在 RemoteAccountViewModel / RemoteSyncService。
 */

import { RemoteErrorCode, SyncResult } from '../model/Remote';
import { remoteAccountViewModel } from '../viewmodel/RemoteAccountViewModel';
import { remoteSyncService } from '../service/remote/RemoteSyncService';
import { safeArea } from '../service/SafeAreaController';
import { ToastUtil } from '../common/utils/ToastUtil';
import { appSettings } from '../model/AppSettings';
import { settingsStore } from '../service/SettingsStore';
import { AUTO_REFRESH_OPTIONS, ChoiceOption } from '../model/SettingsOptions';
import { RemoteSyncConstants } from '../common/constants/RssConstants';
import { MaterialController } from '../service/MaterialController';
import { RouterConstants } from '../common/constants/RouterConstants';

@ComponentV2
export struct RemoteServiceView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    remoteAccountViewModel.init().catch(() => {
    });
  }

  /** 同步阶段文案（同步中显示）。 */
  private phaseText(): ResourceStr {
    return remoteAccountViewModel.phaseText(remoteSyncService.phase);
  }

  /** 状态卡里的错误文案：优先展示持久化的最近错误码。 */
  private statusErrorText(): ResourceStr {
    if (remoteAccountViewModel.status.lastError.length === 0) {
      return $r('app.string.remote_status_never');
    }
    return remoteAccountViewModel.errorText(remoteAccountViewModel.status.lastError);
  }

  private isFeedbin(): boolean {
    return remoteAccountViewModel.serviceType === RemoteSyncConstants.SERVICE_TYPE_FEEDBIN;
  }

  private serviceLabel(): ResourceStr {
    return this.isFeedbin()
      ? $r('app.string.remote_service_feedbin')
      : $r('app.string.remote_service_greader');
  }

  /** 已连接账号的服务名（状态卡展示，跟随账号持久化的 serviceType）。 */
  private accountServiceLabel(): ResourceStr {
    return remoteAccountViewModel.account?.serviceType === RemoteSyncConstants.SERVICE_TYPE_FEEDBIN
      ? $r('app.string.remote_status_service_value_feedbin')
      : $r('app.string.remote_status_service_value');
  }

  private connect(): void {
    remoteAccountViewModel.connect().then((ok: boolean) => {
      if (!ok) {
        return;
      }
      ToastUtil.show(this.getUIContext(), $r('app.string.remote_connected'));
      if (remoteAccountViewModel.warningCode !== RemoteErrorCode.NONE) {
        ToastUtil.show(this.getUIContext(),
          remoteAccountViewModel.errorText(remoteAccountViewModel.warningCode));
      }
      if (remoteAccountViewModel.needsMigration) {
        this.showMigrationPrompt();
      }
    });
  }

  private openMigration(): void {
    this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_REMOTE_MIGRATION, ''));
  }

  /** 连接后发现本地独有源：提示是否进入迁移页（不阻塞连接本身）。 */
  private showMigrationPrompt(): void {
    const later: AlertDialogButtonBaseOptions = {
      value: $r('app.string.remote_migration_later'),
      action: () => {
      }
    };
    const go: AlertDialogButtonBaseOptions = {
      value: $r('app.string.remote_migration_go'),
      fontColor: $r('app.color.hm_brand'),
      action: () => {
        this.openMigration();
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.remote_migration_prompt_title'),
      message: $r('app.string.remote_migration_prompt_message', remoteAccountViewModel.localOnlyCount),
      autoCancel: true,
      primaryButton: later,
      secondaryButton: go
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  private syncNow(): void {
    remoteAccountViewModel.syncNow().then((result: SyncResult | undefined) => {
      if (result === undefined) {
        return;
      }
      ToastUtil.show(this.getUIContext(),
        $r('app.string.remote_sync_summary', result.feedsAdded, result.articlesAdded, result.statesPushed));
    });
  }

  private confirmLogout(clearSyncData: boolean): void {
    remoteAccountViewModel.logout(clearSyncData).then(() => {
      ToastUtil.show(this.getUIContext(), $r('app.string.remote_logout_done'));
    });
  }

  @Builder
  SectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize($r('app.float.font_size_section'))
      .fontColor($r('app.color.hm_text_secondary'))
      .margin({ top: $r('app.float.space_xl'), bottom: $r('app.float.space_s'), left: $r('app.float.space_xs') })
  }

  /** 一行「标签 + 右侧取值」。 */
  @Builder
  InfoRow(label: ResourceStr, value: ResourceStr) {
    Row() {
      Text(label)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_primary'))
      Blank()
      Text(value)
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .maxLines(2)
        .textAlign(TextAlign.End)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: $r('app.float.space_m') })
    }
    .width('100%')
    .constraintSize({ minHeight: $r('app.float.row_height') })
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m'), top: $r('app.float.space_s'), bottom: $r('app.float.space_s') })
  }

  /** 表单卡片。 */
  @Builder
  ConnectCard() {
    Column({ space: $r('app.float.space_s') }) {
      Text($r('app.string.remote_field_service'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
      Row() {
        Text(this.serviceLabel())
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([$r('app.color.hm_text_secondary')])
      }
      .width('100%')
      .height($r('app.float.row_height'))
      .padding({ left: $r('app.float.space_s'), right: $r('app.float.space_s') })
      .backgroundColor($r('app.color.hm_page_transparent'))
      .borderRadius($r('app.float.radius_card'))
      .bindMenu(this.ServiceTypeMenu(), MaterialController.menuOptions({}, appSettings.immersiveOn))

      Text($r('app.string.remote_field_base_url'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
      TextInput({ text: remoteAccountViewModel.baseUrl,
        placeholder: this.isFeedbin()
          ? $r('app.string.remote_feedbin_base_hint')
          : $r('app.string.remote_field_base_url_hint') })
        .type(InputType.Normal)
        .fontSize($r('app.float.font_size_body'))
        .onChange((value: string) => {
          remoteAccountViewModel.baseUrl = value;
        })

      Text(this.isFeedbin()
        ? $r('app.string.remote_field_username_email')
        : $r('app.string.remote_field_username'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
      TextInput({ text: remoteAccountViewModel.username })
        .type(InputType.Normal)
        .fontSize($r('app.float.font_size_body'))
        .onChange((value: string) => {
          remoteAccountViewModel.username = value;
        })

      Text($r('app.string.remote_field_password'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
      TextInput({ text: remoteAccountViewModel.password })
        .type(InputType.Password)
        .fontSize($r('app.float.font_size_body'))
        .onChange((value: string) => {
          remoteAccountViewModel.password = value;
        })

      if (!this.isFeedbin()) {
        Row() {
          Text($r('app.string.remote_allow_http'))
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_text_primary'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: remoteAccountViewModel.allowHttp })
            .selectedColor($r('app.color.hm_brand'))
            .onChange((value: boolean) => {
              remoteAccountViewModel.allowHttp = value;
            })
        }
        .width('100%')
        .height($r('app.float.row_height'))

        Text($r('app.string.remote_allow_http_hint'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      }

      Button(remoteAccountViewModel.connecting
        ? $r('app.string.remote_connecting')
        : $r('app.string.remote_connect'))
        .buttonStyle(ButtonStyleMode.NORMAL)
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_on_brand'))
        .backgroundColor($r('app.color.hm_brand'))
        .width('100%')
        .height($r('app.float.row_height'))
        .enabled(!remoteAccountViewModel.connecting)
        .onClick(() => {
          this.connect();
        })

      if (remoteAccountViewModel.errorCode !== RemoteErrorCode.NONE) {
        Text(remoteAccountViewModel.errorText(remoteAccountViewModel.errorCode))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .width('100%')
      }

      Text(this.isFeedbin()
        ? $r('app.string.remote_feedbin_hint')
        : $r('app.string.remote_form_hint'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
      Text($r('app.string.remote_aux_credentials'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 服务类型菜单。 */
  @Builder
  ServiceTypeMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.remote_service_greader') })
        .onClick(() => {
          remoteAccountViewModel.chooseService(RemoteSyncConstants.SERVICE_TYPE_GREADER);
        })
      MenuItem({ content: $r('app.string.remote_service_feedbin') })
        .onClick(() => {
          remoteAccountViewModel.chooseService(RemoteSyncConstants.SERVICE_TYPE_FEEDBIN);
        })
    }
    .width($r('app.float.menu_width'))
    .radius($r('app.float.radius_card'))
  }

  /** 同步状态卡：账号信息 + 同步统计 + 操作。 */
  @Builder
  StatusCard() {
    Column() {
      this.InfoRow($r('app.string.remote_status_service'), this.accountServiceLabel())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.remote_status_base_url'),
        remoteAccountViewModel.account?.baseUrl ?? '')
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.remote_status_username'),
        remoteAccountViewModel.account?.username ?? '')
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.remote_status_feeds'),
        remoteAccountViewModel.feedCount.toString())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.remote_status_last_sync'), remoteAccountViewModel.lastSyncText())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.remote_status_pending'),
        remoteAccountViewModel.status.pending.toString())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.remote_status_failures'),
        remoteAccountViewModel.status.failures.toString())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.remote_status_last_error'), this.statusErrorText())
      Divider().color($r('app.color.hm_divider'))
      this.InfoRow($r('app.string.remote_status_mode'),
        remoteAccountViewModel.modeText(remoteAccountViewModel.subscriptionMode))
      Divider().color($r('app.color.hm_divider'))
      Row({ space: $r('app.float.space_s') }) {
        Text($r('app.string.remote_migration_entry'))
          .fontSize($r('app.float.font_size_caption'))
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
        this.openMigration();
      })
      Divider().color($r('app.color.hm_divider'))
      Row() {
        Text($r('app.string.remote_auto_sync'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_primary'))
        Blank()
        Text(AUTO_REFRESH_OPTIONS.labelOf(appSettings.remoteAutoSync))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .padding({ left: $r('app.float.space_xs') })
      }
      .width('100%')
      .height($r('app.float.row_height'))
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
      .bindMenu(this.AutoSyncMenu())

      if (remoteSyncService.syncing) {
        Divider().color($r('app.color.hm_divider'))
        Row({ space: $r('app.float.space_s') }) {
          LoadingProgress()
            .width($r('app.float.icon_size'))
            .height($r('app.float.icon_size'))
            .color($r('app.color.hm_brand'))
          Text(this.phaseText())
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .layoutWeight(1)
          if (remoteSyncService.progressTotal > 0) {
            Text($r('app.string.remote_progress', remoteSyncService.progressDone,
              remoteSyncService.progressTotal))
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_text_secondary'))
          }
        }
        .width('100%')
        .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m'), top: $r('app.float.space_s'), bottom: $r('app.float.space_s') })
      }

      Row({ space: $r('app.float.space_s') }) {
        Button(remoteSyncService.syncing
          ? $r('app.string.remote_syncing')
          : $r('app.string.remote_sync_now'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .enabled(!remoteSyncService.syncing)
          .onClick(() => {
            this.syncNow();
          })
        Button($r('app.string.remote_logout'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .bindMenu(this.LogoutMenu())
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m'), top: $r('app.float.space_s'), bottom: $r('app.float.space_m') })
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 自动同步间隔菜单（复用自动刷新的档位：关 / 15 / 30 / 60 分钟）。 */
  @Builder
  AutoSyncMenu() {
    Menu() {
      ForEach(AUTO_REFRESH_OPTIONS.options, (option: ChoiceOption) => {
        MenuItem({ content: option.label })
          .onClick(() => {
            appSettings.remoteAutoSync = option.id;
            settingsStore.save();
          })
      }, (option: ChoiceOption) => option.id)
    }
    .width($r('app.float.menu_width'))
    .radius($r('app.float.radius_card'))
  }

  /** 退出登录菜单：默认保留本地数据，也可清除同步映射 / 队列。 */
  @Builder
  LogoutMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.remote_logout_keep') })
        .onClick(() => {
          this.confirmLogout(false);
        })
      MenuItem({ content: $r('app.string.remote_logout_clear') })
        .onClick(() => {
          this.confirmLogout(true);
        })
    }
    .width($r('app.float.menu_width'))
    .radius($r('app.float.radius_card'))
  }

  build() {
    Scroll(this.scroller) {
      Column() {
        Row().width('100%').height(safeArea.contentTopInsetVp)

        this.SectionTitle($r('app.string.remote_section_connect'))
        this.ConnectCard()

        if (remoteAccountViewModel.isConnected()) {
          this.SectionTitle($r('app.string.remote_section_status'))
          this.StatusCard()
        } else {
          Text($r('app.string.remote_empty_status'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .margin({ top: $r('app.float.space_m'), left: $r('app.float.space_xs') })
        }

        Blank().height(safeArea.contentBottomInsetVp)
      }
      .width('100%')
      .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    // Scroll 默认会把「内容比视口短」的内容整体居中，首屏顶部会多出一条空白；固定从顶部排。
    .align(Alignment.TopStart)
    .clip(false)
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
