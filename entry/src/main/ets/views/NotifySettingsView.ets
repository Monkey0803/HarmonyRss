/*
 * NotifySettingsView.ets — 通知设置页（NavDestination 内容，纯状态管理 V2）。
 *
 * 页面只做展示与事件上报：策略编辑与落盘都在 NotifyViewModel（save() 一次写入
 * NotifyStore + SettingsStore，下一次抓取立即生效），通知发布在 NotifyService。
 *
 * 交互约定：
 *   - 授权状态卡片：未授权时给「申请授权」；被拒绝过一次后只展示引导文案 + 「重新检查」，
 *     不再重复弹系统授权框（FR-012）。
 *   - 总开关复用 SettingsViewModel.setNotifyNewArticles：开启会先申请系统授权，
 *     失败时该 ViewModel 自己把 appSettings.notifyNewArticles 落回 false，界面据此回退。
 *   - 免打扰起止、摘要小时都用系统 TimePickerDialog（24 小时制），保存为「当天第几分钟」/ 小时数。
 *   - 关键词：输入框 + 添加按钮 + chips，归一（trim / 大小写不敏感去重 / 上限 20）在 ViewModel。
 *   - 任何改动即时 save()：没有「保存」按钮，避免用户改完忘记落盘。
 *
 * 关键约束：动态行的值一律在 build 里直接读 @Trace 单例（appSettings / notifyViewModel），
 * 不用多参 @Builder 传值 —— 多参 @Builder 不随状态刷新（见 SettingsTabView 的说明）。
 * 尺寸与颜色全部走 resources。
 */

import { common } from '@kit.AbilityKit';
import { appSettings } from '../model/AppSettings';
import { CommonConstants } from '../common/constants/CommonConstants';
import { notifyViewModel } from '../viewmodel/NotifyViewModel';
import { settingsViewModel } from '../viewmodel/SettingsViewModel';
import { safeArea } from '../service/SafeAreaController';
import { ToastUtil } from '../common/utils/ToastUtil';

/** 关键词输入框的最大长度（字符）：只防手滑，真正的上限是关键词条数。 */
const KEYWORD_INPUT_MAX: number = 40;

/** 分钟数 → 「HH:mm」（24 小时制，免打扰起止时间展示用）。 */
function clockOf(minuteOfDay: number): string {
  const hour: number = Math.floor(minuteOfDay / 60);
  const minute: number = minuteOfDay % 60;
  const hourText: string = hour < 10 ? '0' + hour.toString() : hour.toString();
  const minuteText: string = minute < 10 ? '0' + minute.toString() : minute.toString();
  return hourText + ':' + minuteText;
}

/** 小时 → 「HH:00」（每日摘要展示用）。 */
function hourTextOf(hour: number): string {
  return (hour < 10 ? '0' + hour.toString() : hour.toString()) + ':00';
}

@ComponentV2
export struct NotifySettingsView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  /** 关键词输入框内容（添加成功后清空）。 */
  @Local keywordDraft: string = '';
  /** 本次会话已拒绝过授权：不再重复弹系统框，只展示引导 + 「重新检查」。 */
  @Local deniedOnce: boolean = false;
  /** 授权请求进行中（防重复点击）。 */
  @Local asking: boolean = false;
  /** 总开关切换中：申请授权是异步的，期间禁用开关避免连点。 */
  @Local switching: boolean = false;
  /** 测试通知发送中。 */
  @Local testing: boolean = false;

  aboutToAppear(): void {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    // init 打开通知偏好库 + 设置库并读出策略；whenReady 之后系统授权状态才是准的。
    notifyViewModel.init(context);
    notifyViewModel.whenReady().then(() => {
      notifyViewModel.refreshPermission();
    });
  }

  /** 宿主 Ability 上下文（申请授权 / 发测试通知要用 UIAbilityContext）。 */
  private ability(): common.UIAbilityContext | undefined {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      return undefined;
    }
    return context as common.UIAbilityContext;
  }

  /** 把当前编辑中的策略落盘（切换开关 / 选完时间 / 增删关键词后调用）。 */
  private persist(): void {
    notifyViewModel.save();
  }

  /** 申请通知授权；被拒绝时只记一次状态并展示引导，不重复弹窗。 */
  private async askPermission(): Promise<void> {
    const ability: common.UIAbilityContext | undefined = this.ability();
    if (ability === undefined) {
      return;
    }
    this.asking = true;
    const granted: boolean = await notifyViewModel.requestPermission(ability);
    this.asking = false;
    if (granted) {
      this.deniedOnce = false;
      return;
    }
    this.deniedOnce = true;
    ToastUtil.show(this.getUIContext(), $r('app.string.toast_notify_denied'));
  }

  /**
   * 总开关：先落设置（内部会按需申请授权），失败时保持关闭并提示。
   * 值没变（例如界面重建触发的回调）直接忽略，避免自激。
   */
  private toggleMaster(value: boolean): void {
    if (value === appSettings.notifyNewArticles || this.switching) {
      return;
    }
    const ability: common.UIAbilityContext | undefined = this.ability();
    if (ability === undefined) {
      return;
    }
    this.switching = true;
    settingsViewModel.setNotifyNewArticles(value, ability).then((granted: boolean) => {
      this.switching = false;
      notifyViewModel.refreshPermission();
      if (value && !granted) {
        // setNotifyNewArticles 内部已把开关落回 false，界面会随之回退。
        this.deniedOnce = true;
        ToastUtil.show(this.getUIContext(), $r('app.string.toast_notify_denied'));
      }
    });
  }

  /** 免打扰开关。 */
  private toggleDnd(value: boolean): void {
    if (value === notifyViewModel.dndEnabled) {
      return;
    }
    notifyViewModel.setDndEnabled(value);
    this.persist();
  }

  /** 每日摘要开关。 */
  private toggleDigest(value: boolean): void {
    if (value === notifyViewModel.digestEnabled) {
      return;
    }
    notifyViewModel.setDigestEnabled(value);
    this.persist();
  }

  /** 选免打扰的起点 / 终点（24 小时制），保存为当天第几分钟。 */
  private pickDndTime(isStart: boolean): void {
    const current: number = isStart ? notifyViewModel.dndStart : notifyViewModel.dndEnd;
    const selected: Date = new Date();
    selected.setHours(Math.floor(current / 60), current % 60, 0, 0);
    this.getUIContext().showTimePickerDialog({
      selected: selected,
      useMilitaryTime: true,
      onAccept: (value: TimePickerResult) => {
        const minutes: number = value.hour * 60 + value.minute;
        if (isStart) {
          notifyViewModel.setDndRange(minutes, notifyViewModel.dndEnd);
        } else {
          notifyViewModel.setDndRange(notifyViewModel.dndStart, minutes);
        }
        this.persist();
      }
    });
  }

  /** 选每日摘要的触发小时（只取小时，分钟固定 00）。 */
  private pickDigestHour(): void {
    const selected: Date = new Date();
    selected.setHours(notifyViewModel.digestHour, 0, 0, 0);
    this.getUIContext().showTimePickerDialog({
      selected: selected,
      useMilitaryTime: true,
      onAccept: (value: TimePickerResult) => {
        notifyViewModel.setDigestHour(value.hour);
        this.persist();
      }
    });
  }

  /** 添加关键词：空串忽略，重复 / 达上限给出提示。 */
  private addKeyword(): void {
    const text: string = this.keywordDraft;
    if (text.trim().length === 0) {
      return;
    }
    if (notifyViewModel.keywords.length >= CommonConstants.NOTIFY_KEYWORD_MAX) {
      ToastUtil.show(this.getUIContext(),
        $r('app.string.notify_keywords_full', CommonConstants.NOTIFY_KEYWORD_MAX));
      return;
    }
    if (!notifyViewModel.addKeyword(text)) {
      // 上限已在上面拦掉，这里只剩「已存在」。
      ToastUtil.show(this.getUIContext(), $r('app.string.notify_keyword_exists'));
      return;
    }
    this.keywordDraft = '';
    this.persist();
  }

  /** 删除关键词（点击 chip 上的关闭图标或整块 chip）。 */
  private removeKeyword(keyword: string): void {
    if (notifyViewModel.removeKeyword(keyword)) {
      this.persist();
    }
  }

  /** 发送测试通知：未授权或发布失败都给明确提示，不静默。 */
  private sendTest(): void {
    const ability: common.UIAbilityContext | undefined = this.ability();
    if (ability === undefined) {
      return;
    }
    this.testing = true;
    notifyViewModel.test(ability).then((ok: boolean) => {
      this.testing = false;
      if (ok) {
        ToastUtil.show(this.getUIContext(), $r('app.string.notify_test_sent'));
        return;
      }
      ToastUtil.show(this.getUIContext(), $r('app.string.notify_test_failed'));
      notifyViewModel.refreshPermission();
    });
  }

  /** 重新读一次系统授权状态（用户去系统设置里开启后回来点这个）。 */
  private refreshPermission(): void {
    notifyViewModel.refreshPermission();
    if (notifyViewModel.authorized) {
      this.deniedOnce = false;
    }
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

  /** 权限卡片：状态 + 申请授权 / 重新检查 + 引导文案。 */
  @Builder
  PermissionCard() {
    Column({ space: $r('app.float.space_s') }) {
      Row({ space: $r('app.float.space_s') }) {
        SymbolGlyph(notifyViewModel.authorized ? $r('sys.symbol.bell') : $r('sys.symbol.bell_slash'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([notifyViewModel.authorized
            ? $r('app.color.hm_brand')
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
              .fontColor($r('app.color.hm_brand'))
              .onClick(() => {
                this.refreshPermission();
              })
          } else {
            Button($r('app.string.notify_permission_grant'))
              .buttonStyle(ButtonStyleMode.NORMAL)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.hm_on_brand'))
              .backgroundColor($r('app.color.hm_brand'))
              .enabled(!this.asking)
              .onClick(() => {
                this.askPermission();
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

  /** 通知范围卡片：总开关 + 关键词。 */
  @Builder
  PolicyCard() {
    Column() {
      Row({ space: $r('app.float.space_s') }) {
        Column({ space: $r('app.float.space_xxs') }) {
          Text($r('app.string.notify_global_switch'))
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_text_primary'))
            .width('100%')
          Text($r('app.string.notify_global_switch_desc'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: appSettings.notifyNewArticles })
          .selectedColor($r('app.color.hm_brand'))
          .enabled(!this.switching)
          .onChange((value: boolean) => {
            this.toggleMaster(value);
          })
      }
      .width('100%')
      .padding({
        left: $r('app.float.space_m'),
        right: $r('app.float.space_m'),
        top: $r('app.float.space_m'),
        bottom: $r('app.float.space_m')
      })

      Divider().color($r('app.color.hm_divider'))

      Column({ space: $r('app.float.space_s') }) {
        Text($r('app.string.notify_keywords_title'))
          .fontSize($r('app.float.font_size_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hm_text_primary'))
          .width('100%')
        Text($r('app.string.notify_keywords_desc'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')

        Row({ space: $r('app.float.space_s') }) {
          TextInput({
            text: this.keywordDraft,
            placeholder: $r('app.string.notify_keywords_placeholder')
          })
            .type(InputType.Normal)
            .maxLength(KEYWORD_INPUT_MAX)
            .fontSize($r('app.float.font_size_body'))
            .layoutWeight(1)
            .onChange((value: string) => {
              this.keywordDraft = value;
            })
            .onSubmit(() => {
              this.addKeyword();
            })
          Button($r('app.string.notify_keywords_add'))
            .buttonStyle(ButtonStyleMode.NORMAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_on_brand'))
            .backgroundColor($r('app.color.hm_brand'))
            .enabled(notifyViewModel.keywords.length < CommonConstants.NOTIFY_KEYWORD_MAX)
            .onClick(() => {
              this.addKeyword();
            })
        }
        .width('100%')

        if (notifyViewModel.keywords.length === 0) {
          Text($r('app.string.notify_keywords_empty'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
        } else {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(notifyViewModel.keywords, (keyword: string) => {
              Row({ space: $r('app.float.space_xs') }) {
                Text(keyword)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.hm_text_primary'))
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize($r('app.float.icon_size_tiny'))
                  .fontColor([$r('app.color.hm_text_secondary')])
              }
              .height($r('app.float.value_chip_height'))
              .padding({
                left: $r('app.float.space_m'),
                right: $r('app.float.space_s')
              })
              .margin({ right: $r('app.float.space_s'), bottom: $r('app.float.space_s') })
              .backgroundColor($r('app.color.hm_value_chip_background'))
              .borderRadius($r('app.float.radius_chip'))
              .accessibilityText($r('app.string.notify_keyword_remove', keyword))
              .onClick(() => {
                this.removeKeyword(keyword);
              })
            }, (keyword: string) => keyword)
          }
          .width('100%')
        }

        Text($r('app.string.notify_keywords_full', CommonConstants.NOTIFY_KEYWORD_MAX))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      }
      .width('100%')
      .padding($r('app.float.space_m'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  /** 免打扰卡片：开关 + 起止时间（点击弹系统时间选择器）。 */
  @Builder
  DndCard() {
    Column() {
      Row({ space: $r('app.float.space_s') }) {
        Column({ space: $r('app.float.space_xxs') }) {
          Text($r('app.string.notify_dnd_title'))
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_text_primary'))
            .width('100%')
          Text($r('app.string.notify_dnd_desc'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: notifyViewModel.dndEnabled })
          .selectedColor($r('app.color.hm_brand'))
          .onChange((value: boolean) => {
            this.toggleDnd(value);
          })
      }
      .width('100%')
      .padding({
        left: $r('app.float.space_m'),
        right: $r('app.float.space_m'),
        top: $r('app.float.space_m'),
        bottom: $r('app.float.space_m')
      })

      Divider().color($r('app.color.hm_divider'))

      Row() {
        Text($r('app.string.notify_dnd_start'))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
        Blank()
        Text(clockOf(notifyViewModel.dndStart))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_secondary'))
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .padding({ left: $r('app.float.space_xs') })
      }
      .width('100%')
      .height($r('app.float.row_height'))
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
      .enabled(notifyViewModel.dndEnabled)
      .opacity(notifyViewModel.dndEnabled ? 1 : 0.4)
      .onClick(() => {
        this.pickDndTime(true);
      })

      Divider().color($r('app.color.hm_divider'))

      Row() {
        Text($r('app.string.notify_dnd_end'))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
        Blank()
        Text(clockOf(notifyViewModel.dndEnd))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_secondary'))
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .padding({ left: $r('app.float.space_xs') })
      }
      .width('100%')
      .height($r('app.float.row_height'))
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
      .enabled(notifyViewModel.dndEnabled)
      .opacity(notifyViewModel.dndEnabled ? 1 : 0.4)
      .onClick(() => {
        this.pickDndTime(false);
      })

      // 起止相同 = 免打扰不生效：明确提示，避免用户以为设了但没生效。
      if (notifyViewModel.dndEnabled && notifyViewModel.dndStart === notifyViewModel.dndEnd) {
        Text($r('app.string.notify_dnd_same'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .width('100%')
          .padding({
            left: $r('app.float.space_m'),
            right: $r('app.float.space_m'),
            bottom: $r('app.float.space_m')
          })
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  /** 每日摘要卡片：开关 + 触发小时。 */
  @Builder
  DigestCard() {
    Column() {
      Row({ space: $r('app.float.space_s') }) {
        Column({ space: $r('app.float.space_xxs') }) {
          Text($r('app.string.notify_digest_title'))
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_text_primary'))
            .width('100%')
          Text($r('app.string.notify_digest_desc'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: notifyViewModel.digestEnabled })
          .selectedColor($r('app.color.hm_brand'))
          .onChange((value: boolean) => {
            this.toggleDigest(value);
          })
      }
      .width('100%')
      .padding({
        left: $r('app.float.space_m'),
        right: $r('app.float.space_m'),
        top: $r('app.float.space_m'),
        bottom: $r('app.float.space_m')
      })

      Divider().color($r('app.color.hm_divider'))

      Row() {
        Text($r('app.string.notify_digest_hour'))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
        Blank()
        Text(hourTextOf(notifyViewModel.digestHour))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_secondary'))
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([$r('app.color.hm_text_secondary')])
          .padding({ left: $r('app.float.space_xs') })
      }
      .width('100%')
      .height($r('app.float.row_height'))
      .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
      .enabled(notifyViewModel.digestEnabled)
      .opacity(notifyViewModel.digestEnabled ? 1 : 0.4)
      .onClick(() => {
        this.pickDigestHour();
      })
    }
    .width('100%')
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
  }

  build() {
    List({ scroller: this.scroller }) {
      ListItem() {
        Column() {
          // 透明标题栏占位：内容可以穿过标题栏下方。
          Row().width('100%').height(safeArea.contentTopInsetVp)

          Text($r('app.string.notify_settings_desc'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .padding({ top: $r('app.float.space_s') })

          this.SectionTitle($r('app.string.notify_section_permission'))
          this.PermissionCard()

          this.SectionTitle($r('app.string.notify_section_policy'))
          this.PolicyCard()

          this.SectionTitle($r('app.string.notify_section_dnd'))
          this.DndCard()

          this.SectionTitle($r('app.string.notify_section_digest'))
          this.DigestCard()

          this.SectionTitle($r('app.string.notify_section_test'))
          Column() {
            Button($r('app.string.notify_test_action'))
              .width('100%')
              .height($r('app.float.row_height'))
              .buttonStyle(ButtonStyleMode.NORMAL)
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.hm_brand'))
              .backgroundColor($r('app.color.hm_menu_item_selected'))
              .enabled(!this.testing)
              .onClick(() => {
                this.sendTest();
              })
          }
          .width('100%')
          .padding($r('app.float.space_m'))
          .backgroundColor($r('app.color.hm_card_background'))
          .borderRadius($r('app.float.radius_card'))

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
