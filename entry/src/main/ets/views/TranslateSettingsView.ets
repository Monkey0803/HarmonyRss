/*
 * TranslateSettingsView.ets — 正文翻译设置页（NavDestination 内容，纯状态管理 V2）。
 *
 * 隐私优先：
 *   - 联网翻译默认关闭；本页是唯一开启入口；
 *   - API Key 只写 Asset Store（TranslateSecretStore），页面只展示「已配置 / 未配置」；
 *   - 清除缓存只删独立翻译缓存库，不碰主库与文章。
 *
 * 交互：所有开关 / 选项即时保存；地址与 Key 在提交（回车 / 保存按钮 / 离开页面）时落盘。
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appSettings } from '../model/AppSettings';
import { TranslationError } from '../model/Translation';
import { TranslateProvider } from '../common/constants/TranslateConstants';
import { translationService } from '../service/TranslationService';
import { translateSecretStore } from '../service/TranslateSecretStore';
import { settingsStore } from '../service/SettingsStore';
import { safeArea } from '../service/SafeAreaController';
import { ToastUtil } from '../common/utils/ToastUtil';
import { translationErrorText, languageText } from '../common/utils/TranslationText';

const DOMAIN: number = 0x0000;
const TAG: string = 'TranslateSettingsView';

@ComponentV2
export struct TranslateSettingsView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  /** 地址草稿（提交时写回 appSettings）。 */
  @Local endpointDraft: string = '';
  /** Key 草稿（保存后立即清空，避免明文常驻界面）。 */
  @Local keyDraft: string = '';
  @Local keySet: boolean = false;
  @Local savingKey: boolean = false;
  @Local testing: boolean = false;
  @Local cacheCount: number = 0;

  aboutToAppear(): void {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    this.endpointDraft = appSettings.translateEndpoint;
    settingsStore.load(context).then(() => {
      this.endpointDraft = appSettings.translateEndpoint;
    });
    this.refreshKeyState();
    this.refreshCacheCount(context);
  }

  /** 离开页面时把地址草稿落盘（onBlur 不一定触发）。 */
  aboutToDisappear(): void {
    this.saveEndpoint();
  }

  private async refreshKeyState(): Promise<void> {
    this.keySet = await translateSecretStore.hasKey();
  }

  private async refreshCacheCount(context: common.Context): Promise<void> {
    this.cacheCount = await translationService.cacheCount(context);
  }

  private contextOrUndefined(): common.Context | undefined {
    return this.getUIContext().getHostContext();
  }

  private saveEndpoint(): void {
    const next: string = this.endpointDraft.trim();
    if (next === appSettings.translateEndpoint) {
      return;
    }
    appSettings.translateEndpoint = next;
    settingsStore.save();
  }

  private toggleEnabled(value: boolean): void {
    appSettings.translateEnabled = value;
    settingsStore.save();
    if (value && !this.keySet && appSettings.translateProvider === TranslateProvider.DEEPL) {
      ToastUtil.show(this.getUIContext(), $r('app.string.translate_api_key_unset'));
    }
  }

  private pickProvider(provider: string): void {
    if (provider === appSettings.translateProvider) {
      return;
    }
    appSettings.translateProvider = provider;
    settingsStore.save();
  }

  private async saveKey(): Promise<void> {
    const text: string = this.keyDraft.trim();
    if (text.length === 0) {
      return;
    }
    this.savingKey = true;
    try {
      await translateSecretStore.save(text);
      this.keyDraft = '';
      this.keySet = true;
      ToastUtil.show(this.getUIContext(), $r('app.string.translate_api_key_set'));
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'save key failed: %{public}d', error.code);
      ToastUtil.show(this.getUIContext(), $r('app.string.translate_error_not_configured'));
    } finally {
      this.savingKey = false;
    }
  }

  private async clearKey(): Promise<void> {
    await translateSecretStore.remove();
    this.keySet = false;
    this.keyDraft = '';
  }

  private async runTest(): Promise<void> {
    const context: common.Context | undefined = this.contextOrUndefined();
    if (context === undefined) {
      return;
    }
    if (!appSettings.translateEnabled) {
      ToastUtil.show(this.getUIContext(), $r('app.string.translate_error_disabled_title'));
      return;
    }
    this.testing = true;
    try {
      const text: string = await translationService.test(context);
      ToastUtil.show(this.getUIContext(), $r('app.string.translate_test_ok', text));
    } catch (err) {
      const code: string = err instanceof TranslationError ? err.code : '';
      ToastUtil.show(this.getUIContext(), translationErrorText(code));
    } finally {
      this.testing = false;
    }
  }

  private async clearCache(): Promise<void> {
    const context: common.Context | undefined = this.contextOrUndefined();
    if (context === undefined) {
      return;
    }
    const cleared: number = await translationService.clearCache(context);
    this.cacheCount = 0;
    ToastUtil.show(this.getUIContext(), $r('app.string.translate_cache_cleared', cleared));
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

  /** 服务选择：两枚 chip（当前服务用品牌色）。值直接读 appSettings，保证状态变化即刷新。 */
  @Builder
  ProviderRow() {
    Column({ space: $r('app.float.space_s') }) {
      Text($r('app.string.translate_provider'))
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')
      Row({ space: $r('app.float.space_s') }) {
        Text($r('app.string.translate_provider_deepl'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(appSettings.translateProvider === TranslateProvider.DEEPL
            ? $r('app.color.hm_on_brand') : $r('app.color.hm_text_primary'))
          .backgroundColor(appSettings.translateProvider === TranslateProvider.DEEPL
            ? $r('app.color.hm_brand') : $r('app.color.hm_value_chip_background'))
          .borderRadius($r('app.float.radius_chip'))
          .padding({
            left: $r('app.float.space_m'),
            right: $r('app.float.space_m'),
            top: $r('app.float.space_xs'),
            bottom: $r('app.float.space_xs')
          })
          .onClick(() => {
            this.pickProvider(TranslateProvider.DEEPL);
          })
        Text($r('app.string.translate_provider_libre'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(appSettings.translateProvider === TranslateProvider.LIBRE
            ? $r('app.color.hm_on_brand') : $r('app.color.hm_text_primary'))
          .backgroundColor(appSettings.translateProvider === TranslateProvider.LIBRE
            ? $r('app.color.hm_brand') : $r('app.color.hm_value_chip_background'))
          .borderRadius($r('app.float.radius_chip'))
          .padding({
            left: $r('app.float.space_m'),
            right: $r('app.float.space_m'),
            top: $r('app.float.space_xs'),
            bottom: $r('app.float.space_xs')
          })
          .onClick(() => {
            this.pickProvider(TranslateProvider.LIBRE);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .alignItems(HorizontalAlign.Start)
  }

  /** 地址输入 + 保存按钮。 */
  @Builder
  EndpointRow() {
    Column({ space: $r('app.float.space_s') }) {
      Text($r('app.string.translate_endpoint'))
        .fontSize($r('app.float.font_size_body'))
        .fontColor($r('app.color.hm_text_primary'))
        .width('100%')
      Row({ space: $r('app.float.space_s') }) {
        TextInput({
          text: this.endpointDraft,
          placeholder: $r('app.string.translate_endpoint_hint')
        })
          .type(InputType.Normal)
          .fontSize($r('app.float.font_size_body'))
          .layoutWeight(1)
          .onChange((value: string) => {
            this.endpointDraft = value;
          })
          .onSubmit(() => {
            this.saveEndpoint();
          })
        Button($r('app.string.translate_endpoint_save'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .onClick(() => {
            this.saveEndpoint();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .alignItems(HorizontalAlign.Start)
  }

  /** API Key 输入 + 状态 + 保存 / 清除。 */
  @Builder
  KeyRow() {
    Column({ space: $r('app.float.space_s') }) {
      Row() {
        Text($r('app.string.translate_api_key'))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
        Blank()
        Text(this.keySet ? $r('app.string.translate_api_key_set') : $r('app.string.translate_api_key_unset'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor(this.keySet ? $r('app.color.hm_brand') : $r('app.color.hm_text_secondary'))
      }
      .width('100%')

      TextInput({
        text: this.keyDraft,
        placeholder: $r('app.string.translate_api_key_hint')
      })
        .type(InputType.Password)
        .fontSize($r('app.float.font_size_body'))
        .width('100%')
        .onChange((value: string) => {
          this.keyDraft = value;
        })
        .onSubmit(() => {
          this.saveKey();
        })

      Row({ space: $r('app.float.space_s') }) {
        Button($r('app.string.translate_api_key_save'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .enabled(!this.savingKey && this.keyDraft.trim().length > 0)
          .onClick(() => {
            this.saveKey();
          })
        if (this.keySet) {
          Button($r('app.string.translate_api_key_clear'))
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_danger'))
            .onClick(() => {
              this.clearKey();
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    List({ scroller: this.scroller }) {
      ListItem() {
        Column() {
          Row().width('100%').height(safeArea.contentTopInsetVp)

          Text($r('app.string.translate_settings_desc'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .padding({ top: $r('app.float.space_s') })

          this.SectionTitle($r('app.string.translate_section_service'))
          Column() {
            Row({ space: $r('app.float.space_s') }) {
              Column({ space: $r('app.float.space_xxs') }) {
                Text($r('app.string.translate_enable'))
                  .fontSize($r('app.float.font_size_body'))
                  .fontColor($r('app.color.hm_text_primary'))
                  .width('100%')
                Text($r('app.string.translate_enable_desc'))
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.hm_text_secondary'))
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: appSettings.translateEnabled })
                .selectedColor($r('app.color.hm_brand'))
                .onChange((value: boolean) => {
                  this.toggleEnabled(value);
                })
            }
            .width('100%')
            .padding($r('app.float.space_m'))

            Divider().color($r('app.color.hm_divider'))
            this.ProviderRow()
            Divider().color($r('app.color.hm_divider'))
            this.EndpointRow()
            Divider().color($r('app.color.hm_divider'))
            this.KeyRow()

            Divider().color($r('app.color.hm_divider'))
            Row() {
              Text($r('app.string.translate_target_lang'))
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.hm_text_primary'))
              Blank()
              Text(languageText(translationService.targetLanguage()))
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.hm_text_secondary'))
            }
            .width('100%')
            .height($r('app.float.row_height'))
            .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
          }
          .width('100%')
          .backgroundColor($r('app.color.hm_card_background'))
          .borderRadius($r('app.float.radius_card'))

          this.SectionTitle($r('app.string.translate_section_test'))
          Column() {
            Button($r('app.string.translate_test'))
              .width('100%')
              .height($r('app.float.row_height'))
              .buttonStyle(ButtonStyleMode.NORMAL)
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.hm_brand'))
              .backgroundColor($r('app.color.hm_menu_item_selected'))
              .enabled(!this.testing)
              .onClick(() => {
                this.runTest();
              })
          }
          .width('100%')
          .padding($r('app.float.space_m'))
          .backgroundColor($r('app.color.hm_card_background'))
          .borderRadius($r('app.float.radius_card'))

          Text($r('app.string.translate_privacy'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })

          this.SectionTitle($r('app.string.translate_section_cache'))
          Column() {
            Row() {
              Text($r('app.string.translate_cache_count', this.cacheCount))
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.hm_text_primary'))
            }
            .width('100%')
            .height($r('app.float.row_height'))
            .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })

            Divider().color($r('app.color.hm_divider'))

            Row() {
              Text($r('app.string.translate_cache_clear'))
                .fontSize($r('app.float.font_size_body'))
                .fontColor($r('app.color.hm_danger'))
            }
            .width('100%')
            .height($r('app.float.row_height'))
            .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
            .onClick(() => {
              this.clearCache();
            })
          }
          .width('100%')
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
