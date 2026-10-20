/*
 * SettingsStore.ets — 设置的落盘与恢复（@ohos.data.preferences）。
 *
 * 只存语义 id / 布尔量，逐键存：读出来先归一（`ChoiceSet.normalize`），脏值退回默认项。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { appSettings } from '../model/AppSettings';
import { ARCHIVE_OPTIONS, LIST_DENSITY_OPTIONS, ROW_LAYOUT_OPTIONS, SUMMARY_LINES_OPTIONS, THEME_OPTIONS, LANGUAGE_OPTIONS, MATERIAL_TYPE_OPTIONS, MATERIAL_LEVEL_OPTIONS, BACKGROUND_OPTIONS, LOGO_OPTIONS, AUTO_REFRESH_OPTIONS, READER_FONT_OPTIONS, READER_LINE_OPTIONS, READER_FAMILY_OPTIONS, READER_WIDTH_OPTIONS, READER_ALIGN_OPTIONS, READER_THEME_OPTIONS } from '../model/SettingsOptions';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';
import { ReaderTypography } from '../common/constants/SettingsConstants';
import { normalizeArticleFilter, normalizeReaderViewMode } from '../common/constants/RssConstants';

export class SettingsStore {
  private store: preferences.Preferences | undefined = undefined;

  /** 打开偏好库并把已存的值读进 appSettings。首次运行读不到值就保持默认。 */
  async load(context: common.Context): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context, PreferencesConstants.STORE_NAME);
      this.store = store;
      const theme: string = store.getSync(PreferencesConstants.KEY_THEME_MODE, appSettings.themeMode) as string;
      const language: string = store.getSync(PreferencesConstants.KEY_LANGUAGE_MODE, appSettings.languageMode) as string;
      const materialType: string = store.getSync(PreferencesConstants.KEY_MATERIAL_TYPE, appSettings.materialType) as string;
      const materialLevel: string = store.getSync(PreferencesConstants.KEY_MATERIAL_LEVEL, appSettings.materialLevel) as string;
      const backgroundKind: string =
        store.getSync(PreferencesConstants.KEY_BACKGROUND_KIND, appSettings.backgroundKind) as string;
      const backgroundImagePath: string =
        store.getSync(PreferencesConstants.KEY_BACKGROUND_IMAGE_PATH, appSettings.backgroundImagePath) as string;
      const titleBarScroll: boolean =
        store.getSync(PreferencesConstants.KEY_TITLE_BAR_SCROLL, appSettings.titleBarScrollsWithContent) as boolean;
      const statusBarScroll: boolean =
        store.getSync(PreferencesConstants.KEY_STATUS_BAR_SCROLL, appSettings.statusBarScrollsWithContent) as boolean;
      appSettings.themeMode = THEME_OPTIONS.normalize(theme);
      appSettings.languageMode = LANGUAGE_OPTIONS.normalize(language);
      appSettings.materialType = MATERIAL_TYPE_OPTIONS.normalize(materialType);
      appSettings.materialLevel = MATERIAL_LEVEL_OPTIONS.normalize(materialLevel);
      appSettings.backgroundKind = BACKGROUND_OPTIONS.normalize(backgroundKind);
      appSettings.backgroundImagePath = backgroundImagePath;
      appSettings.titleBarScrollsWithContent = titleBarScroll;
      appSettings.statusBarScrollsWithContent = statusBarScroll;
      appSettings.logoKind = LOGO_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_LOGO_KIND, appSettings.logoKind) as string);
      appSettings.autoRefresh = AUTO_REFRESH_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_AUTO_REFRESH, appSettings.autoRefresh) as string);
      appSettings.readerFont = READER_FONT_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_READER_FONT, appSettings.readerFont) as string);
      appSettings.readerLine = READER_LINE_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_READER_LINE, appSettings.readerLine) as string);
      // 字号 / 行距已改为连续倍数：老库里只有档位 id 时按预设换算成倍数（迁移），
      // 之后两者保持一致（倍数为准，档位由倍数推出，供设置页档位行显示）。
      const fontScale: number = store.getSync(PreferencesConstants.KEY_READER_FONT_SCALE,
        ReaderTypography.fontScaleOfPreset(appSettings.readerFont)) as number;
      const lineScale: number = store.getSync(PreferencesConstants.KEY_READER_LINE_SCALE,
        ReaderTypography.lineScaleOfPreset(appSettings.readerLine)) as number;
      appSettings.readerFontScale = fontScale;
      appSettings.readerLineScale = lineScale;
      appSettings.readerFont = ReaderTypography.fontPresetOfScale(fontScale);
      appSettings.readerLine = ReaderTypography.linePresetOfScale(lineScale);
      appSettings.readerKeepScreenOn =
        store.getSync(PreferencesConstants.KEY_READER_KEEP_SCREEN_ON, appSettings.readerKeepScreenOn) as boolean;
      appSettings.readerFontFamily = READER_FAMILY_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_READER_FAMILY, appSettings.readerFontFamily) as string);
      appSettings.readerWidth = READER_WIDTH_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_READER_WIDTH, appSettings.readerWidth) as string);
      appSettings.readerAlign = READER_ALIGN_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_READER_ALIGN, appSettings.readerAlign) as string);
      appSettings.readerTheme = READER_THEME_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_READER_THEME, appSettings.readerTheme) as string);
      appSettings.notifyNewArticles =
        store.getSync(PreferencesConstants.KEY_NOTIFY_NEW, appSettings.notifyNewArticles) as boolean;
      appSettings.immersiveOn = store.getSync(PreferencesConstants.KEY_IMMERSIVE_ON, appSettings.immersiveOn) as boolean;
      appSettings.pointLightEnabled = store.getSync(PreferencesConstants.KEY_POINT_LIGHT, appSettings.pointLightEnabled) as boolean;
      appSettings.gripEnabled = store.getSync(PreferencesConstants.KEY_GRIP_ENABLED, appSettings.gripEnabled) as boolean;
      appSettings.antiPeepEnabled = store.getSync(PreferencesConstants.KEY_ANTI_PEEP_ENABLED, appSettings.antiPeepEnabled) as boolean;
      appSettings.listNewestFirst =
        store.getSync(PreferencesConstants.KEY_LIST_NEWEST_FIRST, appSettings.listNewestFirst) as boolean;
      appSettings.listGroupMode = store.getSync(PreferencesConstants.KEY_LIST_GROUP_MODE, appSettings.listGroupMode) as string;
      appSettings.homeFilter = normalizeArticleFilter(
        store.getSync(PreferencesConstants.KEY_HOME_FILTER, appSettings.homeFilter) as string);
      appSettings.readerViewMode = normalizeReaderViewMode(
        store.getSync(PreferencesConstants.KEY_READER_VIEW_MODE, appSettings.readerViewMode) as string);
      appSettings.lastTabIndex = store.getSync(PreferencesConstants.KEY_LAST_TAB, appSettings.lastTabIndex) as number;
      appSettings.listRowLayout = ROW_LAYOUT_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_ROW_LAYOUT, appSettings.listRowLayout) as string);
      appSettings.listSummaryLines = SUMMARY_LINES_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_SUMMARY_LINES, appSettings.listSummaryLines) as string);
      appSettings.listDensity = LIST_DENSITY_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_LIST_DENSITY, appSettings.listDensity) as string);
      appSettings.archiveRule = ARCHIVE_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_ARCHIVE_RULE, appSettings.archiveRule) as string);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('SettingsStore.load failed: ' + error.code.toString());
    }
  }

  /** 把当前 appSettings 全量写回。任何一次用户改动后调用。 */
  save(): void {
    const store: preferences.Preferences | undefined = this.store;
    if (store === undefined) {
      return;
    }
    // putSync 标注了可能抛异常，ArkTS 要求调用点必须 catch；
    // 落盘失败只影响下次启动的恢复，不应该中断当前操作，所以吞掉并记日志。
    try {
      store.putSync(PreferencesConstants.KEY_THEME_MODE, appSettings.themeMode);
      store.putSync(PreferencesConstants.KEY_LANGUAGE_MODE, appSettings.languageMode);
      store.putSync(PreferencesConstants.KEY_MATERIAL_TYPE, appSettings.materialType);
      store.putSync(PreferencesConstants.KEY_MATERIAL_LEVEL, appSettings.materialLevel);
      store.putSync(PreferencesConstants.KEY_BACKGROUND_KIND, appSettings.backgroundKind);
      store.putSync(PreferencesConstants.KEY_BACKGROUND_IMAGE_PATH, appSettings.backgroundImagePath);
      store.putSync(PreferencesConstants.KEY_TITLE_BAR_SCROLL, appSettings.titleBarScrollsWithContent);
      store.putSync(PreferencesConstants.KEY_STATUS_BAR_SCROLL, appSettings.statusBarScrollsWithContent);
      store.putSync(PreferencesConstants.KEY_IMMERSIVE_ON, appSettings.immersiveOn);
      store.putSync(PreferencesConstants.KEY_POINT_LIGHT, appSettings.pointLightEnabled);
      store.putSync(PreferencesConstants.KEY_GRIP_ENABLED, appSettings.gripEnabled);
      store.putSync(PreferencesConstants.KEY_ANTI_PEEP_ENABLED, appSettings.antiPeepEnabled);
      store.putSync(PreferencesConstants.KEY_LOGO_KIND, appSettings.logoKind);
      store.putSync(PreferencesConstants.KEY_AUTO_REFRESH, appSettings.autoRefresh);
      store.putSync(PreferencesConstants.KEY_READER_KEEP_SCREEN_ON, appSettings.readerKeepScreenOn);
      store.putSync(PreferencesConstants.KEY_READER_FONT, appSettings.readerFont);
      store.putSync(PreferencesConstants.KEY_READER_LINE, appSettings.readerLine);
      store.putSync(PreferencesConstants.KEY_READER_FONT_SCALE, appSettings.readerFontScale);
      store.putSync(PreferencesConstants.KEY_READER_LINE_SCALE, appSettings.readerLineScale);
      store.putSync(PreferencesConstants.KEY_READER_FAMILY, appSettings.readerFontFamily);
      store.putSync(PreferencesConstants.KEY_READER_WIDTH, appSettings.readerWidth);
      store.putSync(PreferencesConstants.KEY_READER_ALIGN, appSettings.readerAlign);
      store.putSync(PreferencesConstants.KEY_READER_THEME, appSettings.readerTheme);
      store.putSync(PreferencesConstants.KEY_NOTIFY_NEW, appSettings.notifyNewArticles);
      store.putSync(PreferencesConstants.KEY_LIST_NEWEST_FIRST, appSettings.listNewestFirst);
      store.putSync(PreferencesConstants.KEY_LIST_GROUP_MODE, appSettings.listGroupMode);
      store.putSync(PreferencesConstants.KEY_HOME_FILTER, appSettings.homeFilter);
      store.putSync(PreferencesConstants.KEY_READER_VIEW_MODE, appSettings.readerViewMode);
      store.putSync(PreferencesConstants.KEY_LAST_TAB, appSettings.lastTabIndex);
      store.putSync(PreferencesConstants.KEY_ARCHIVE_RULE, appSettings.archiveRule);
      store.putSync(PreferencesConstants.KEY_ROW_LAYOUT, appSettings.listRowLayout);
      store.putSync(PreferencesConstants.KEY_SUMMARY_LINES, appSettings.listSummaryLines);
      store.putSync(PreferencesConstants.KEY_LIST_DENSITY, appSettings.listDensity);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('SettingsStore.putSync failed: ' + error.code.toString());
      return;
    }
    store.flush().catch((err: BusinessError) => {
      console.error('SettingsStore.flush failed: ' + err.code.toString());
    });
  }
}

export const settingsStore: SettingsStore = new SettingsStore();
