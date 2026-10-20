/*
 * SettingsViewModel.ets — 设置的装配与副作用（@ObservedV2）。
 *
 * 界面只读 appSettings 的字段；任何一次用户改动都经由这里：写状态 → 应用副作用 → 落盘。
 */

import { common } from '@kit.AbilityKit';
import { ReaderTypography } from '../common/constants/SettingsConstants';
import { appSettings } from '../model/AppSettings';
import { settingsStore } from '../service/SettingsStore';
import { ThemeController } from '../service/ThemeController';
import { LocaleController } from '../service/LocaleController';
import { MaterialController } from '../service/MaterialController';
import { antiPeep } from '../service/AntiPeep';
import { gripSensor } from '../service/GripSensor';
import { backgroundImageService } from '../service/BackgroundImageService';
import { appIconService } from '../service/AppIconService';
import { backgroundRefresh } from '../service/BackgroundRefresh';
import { notifyService } from '../service/NotifyService';
import { BackgroundKind } from '../common/constants/SettingsConstants';

@ObservedV2
export class SettingsViewModel {
  /** 本机是否支持沉浸式材质（设置页可据此提示降级）。 */
  @Trace immersiveSupported: boolean = true;
  /** 应用级（全局）沉浸光感是否开启（由 module.json5 的 metadata 决定，运行时读取）。 */
  @Trace globalImmersive: boolean = false;

  /** 设置恢复完成的信号：列表展示偏好（排序/分组）要先读到，靠它对齐时序。 */
  private ready: Promise<void> | undefined = undefined;

  /** 启动时装配：恢复落盘设置 → 应用主题与语言 → 恢复防窥订阅（不弹窗）→ 同步后台任务。 */
  init(context: common.Context): void {
    this.ready = this.load(context);
    backgroundRefresh.sync(context);
  }

  /** 等待设置恢复完成（未 init 时立即返回；可重复 await）。 */
  async whenReady(): Promise<void> {
    const pending: Promise<void> | undefined = this.ready;
    if (pending === undefined) {
      return;
    }
    await pending;
  }

  private async load(context: common.Context): Promise<void> {
    await settingsStore.load(context);
    ThemeController.apply(context, appSettings.themeMode);
    LocaleController.apply(appSettings.languageMode);
    this.immersiveSupported = MaterialController.immersiveSupported();
    this.globalImmersive = MaterialController.globalEnabled();
    if (appSettings.antiPeepEnabled) {
      await antiPeep.setEnabled(true);
    }
    // 智感握姿：开关开启时订阅握持手识别（设备不支持时内部粘性降级）。
    gripSensor.setEnabled(appSettings.gripEnabled);
  }

  setTheme(context: common.Context, id: string): void {
    appSettings.themeMode = id;
    ThemeController.apply(context, id);
    settingsStore.save();
  }

  setLanguage(id: string): void {
    appSettings.languageMode = id;
    LocaleController.apply(id);
    settingsStore.save();
  }

  setImmersiveOn(value: boolean): void {
    appSettings.immersiveOn = value;
    settingsStore.save();
  }

  setPointLightEnabled(value: boolean): void {
    appSettings.pointLightEnabled = value;
    settingsStore.save();
  }

  setMaterialType(id: string): void {
    appSettings.materialType = id;
    settingsStore.save();
  }

  setMaterialLevel(id: string): void {
    appSettings.materialLevel = id;
    settingsStore.save();
  }

  /** 切换全局背景图（默认图 / 极光 / 暮色 / 自定义 / 关闭）。 */
  setBackgroundKind(id: string): void {
    appSettings.backgroundKind = id;
    settingsStore.save();
  }

  /** 切换「标题栏随内容滚动」：开启后滚动内容时标题栏会自动收起。 */
  setTitleBarScroll(value: boolean): void {
    appSettings.titleBarScrollsWithContent = value;
    settingsStore.save();
  }

  /** 切换「状态栏随内容滚动」：开启后滚动内容时状态栏会一并收起（沉浸光感建议开）。 */
  setStatusBarScroll(value: boolean): void {
    appSettings.statusBarScrollsWithContent = value;
    settingsStore.save();
  }

  /** 自动刷新间隔：'off' | '15' | '30' | '60'（分钟）；同时重排后台任务。 */
  setAutoRefresh(id: string, context: common.Context): void {
    appSettings.autoRefresh = id;
    settingsStore.save();
    backgroundRefresh.sync(context);
  }

  /**
   * 正文字号倍数（连续值，详情页「阅读排版」面板的 Slider 用）。
   * 拖动过程中只改内存值做实时预览，落盘由调用方在松手时调 persistReaderTypography()。
   */
  setReaderFontScale(scale: number): void {
    appSettings.readerFontScale = scale;
    appSettings.readerFont = ReaderTypography.fontPresetOfScale(scale);
  }

  /** 正文行距倍数（连续值）。 */
  setReaderLineScale(scale: number): void {
    appSettings.readerLineScale = scale;
    appSettings.readerLine = ReaderTypography.linePresetOfScale(scale);
  }

  /** 连续排版参数落盘（Slider 松手 / 面板关闭时调一次，避免拖动过程频繁写盘）。 */
  persistReaderTypography(): void {
    settingsStore.save();
  }

  /** 正文字号档位（快捷预设：写进连续倍数，两者保持一致）。 */
  setReaderFont(id: string): void {
    appSettings.readerFontScale = ReaderTypography.fontScaleOfPreset(id);
    appSettings.readerFont = id;
    settingsStore.save();
  }

  /** 正文行距档位（快捷预设）。 */
  setReaderLine(id: string): void {
    appSettings.readerLineScale = ReaderTypography.lineScaleOfPreset(id);
    appSettings.readerLine = id;
    settingsStore.save();
  }

  /** 阅读时常亮屏幕。 */
  setReaderKeepScreenOn(value: boolean): void {
    appSettings.readerKeepScreenOn = value;
    settingsStore.save();
  }

  /** 正文字体族。 */
  setReaderFontFamily(id: string): void {
    appSettings.readerFontFamily = id;
    settingsStore.save();
  }

  /** 阅读栏宽。 */
  setReaderWidth(id: string): void {
    appSettings.readerWidth = id;
    settingsStore.save();
  }

  /** 正文对齐方式。 */
  setReaderAlign(id: string): void {
    appSettings.readerAlign = id;
    settingsStore.save();
  }

  /** 阅读主题。 */
  setReaderTheme(id: string): void {
    appSettings.readerTheme = id;
    settingsStore.save();
  }

  /**
   * 新文章通知开关。开启时先申请通知授权，拿不到就回退为关闭（避免「开了却没反应」）。
   */
  async setNotifyNewArticles(value: boolean, context: common.UIAbilityContext): Promise<boolean> {
    if (value) {
      const granted: boolean = await notifyService.requestEnable(context);
      appSettings.notifyNewArticles = granted;
      settingsStore.save();
      return granted;
    }
    appSettings.notifyNewArticles = false;
    settingsStore.save();
    return true;
  }

  /**
   * 切换 App logo：先记录并落盘（应用内 logo 立即生效），再尝试同步切换系统桌面图标。
   * 返回系统桌面图标是否切换成功；false 时界面可提示「需上架后生效」。
   */
  async setLogoKind(id: string): Promise<boolean> {
    appSettings.logoKind = id;
    settingsStore.save();
    return await appIconService.selectDynamicIcon(id);
  }

  /** 本机是否支持切换系统桌面图标。 */
  launcherIconSupported(): boolean {
    return appIconService.isSupported();
  }

  /**
   * 从相册选一张图片作为全局背景：选到图片则复制进沙箱并切到「自定义」；
   * 用户取消或失败时保持原背景不变。返回是否切换成功。
   */
  async pickCustomBackground(context: common.Context): Promise<boolean> {
    const path: string = await backgroundImageService.pick(context);
    if (path.length === 0) {
      return false;
    }
    appSettings.backgroundImagePath = path;
    appSettings.backgroundKind = BackgroundKind.CUSTOM;
    settingsStore.save();
    return true;
  }

  setGripEnabled(value: boolean): void {
    appSettings.gripEnabled = value;
    gripSensor.setEnabled(value);
    settingsStore.save();
  }

  setAntiPeepEnabled(value: boolean, context: common.UIAbilityContext): void {
    appSettings.antiPeepEnabled = value;
    this.applyAntiPeep(value, context);
    settingsStore.save();
  }

  private async applyAntiPeep(value: boolean, context: common.UIAbilityContext): Promise<void> {
    await antiPeep.setEnabled(value, context);
  }
}

/** 全局唯一 ViewModel。 */
export const settingsViewModel: SettingsViewModel = new SettingsViewModel();
