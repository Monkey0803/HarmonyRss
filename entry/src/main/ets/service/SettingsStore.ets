/*
 * SettingsStore.ets — 设置的落盘与恢复（@ohos.data.preferences）。
 *
 * 只存语义 id / 布尔量，逐键存：读出来先归一（`ChoiceSet.normalize`），脏值退回默认项。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { appSettings } from '../model/AppSettings';
import { ARCHIVE_OPTIONS, LIST_DENSITY_OPTIONS, ROW_LAYOUT_OPTIONS, SUMMARY_LINES_OPTIONS, THEME_OPTIONS, LANGUAGE_OPTIONS, MATERIAL_TYPE_OPTIONS, MATERIAL_LEVEL_OPTIONS, BACKGROUND_OPTIONS, LOGO_OPTIONS, AUTO_REFRESH_OPTIONS, READER_FONT_OPTIONS, READER_LINE_OPTIONS, READER_FAMILY_OPTIONS, READER_WIDTH_OPTIONS, READER_ALIGN_OPTIONS, READER_THEME_OPTIONS, RETENTION_MODE_OPTIONS, RETENTION_DAYS_OPTIONS } from '../model/SettingsOptions';
import { PreferencesConstants } from '../common/constants/PreferencesConstants';
import { ReaderTypography } from '../common/constants/SettingsConstants';
import { normalizeArticleFilter, normalizeReaderViewMode } from '../common/constants/RssConstants';
import { BackupScalar, BackupSettings } from '../model/Backup';
import { settingsWhitelist } from './BackupCodec';
import { NotifyDefaults } from '../model/Notify';
import { clampDigestHour, clampMinuteOfDay, decodeKeywords, encodeKeywords, normalizeKeywords } from './NotifyPolicy';
import { normalizeProvider } from './TranslationPolicy';

/** 远端自动同步间隔归一：脏值一律退回「关」。 */
export function normalizeRemoteAutoSync(value: string): string {
  if (value === '15' || value === '30' || value === '60') {
    return value;
  }
  return 'off';
}

// ---- 备份段取值辅助（类型不符一律回退当前值，避免脏备份清空设置） ----

function stringValue(value: BackupScalar | undefined, fallback: string): string {
  return typeof value === 'string' && value.length > 0 ? value : fallback;
}

function booleanValue(value: BackupScalar | undefined, fallback: boolean): boolean {
  if (typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'number') {
    return value !== 0;
  }
  if (typeof value === 'string') {
    const normalized: string = value.trim().toLowerCase();
    if (normalized === 'true' || normalized === '1') {
      return true;
    }
    if (normalized === 'false' || normalized === '0') {
      return false;
    }
  }
  return fallback;
}

function numberValue(value: BackupScalar | undefined, fallback: number): number {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : fallback;
  }
  if (typeof value === 'string') {
    const parsed: number = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  }
  return fallback;
}

// ---- 通知策略取值辅助（脏值一律回退 fallback，再归一） ----

/** 偏好库里的「当天第几分钟」：非数字退回 fallback，再夹到 0–1439。 */
function readMinuteOfDay(raw: preferences.ValueType, fallback: number): number {
  const value: number = typeof raw === 'number' ? raw : fallback;
  return clampMinuteOfDay(value, fallback);
}

/** 偏好库里的摘要小时：非数字退回 fallback，再夹到 0–23。 */
function readDigestHour(raw: preferences.ValueType, fallback: number): number {
  const value: number = typeof raw === 'number' ? raw : fallback;
  return clampDigestHour(value, fallback);
}

/** 偏好库里的关键词 JSON：空串 / 非字符串回退当前值；否则解码并归一。 */
function readKeywords(raw: preferences.ValueType, fallback: string[]): string[] {
  if (typeof raw !== 'string' || raw.length === 0) {
    return normalizeKeywords(fallback);
  }
  return decodeKeywords(raw);
}

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
      // 保留策略：老库没有这两个 key，读出来就是默认值（永久保留，绝不因升级删历史）。
      appSettings.retentionMode = RETENTION_MODE_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_RETENTION_MODE, appSettings.retentionMode) as string);
      appSettings.retentionDays = RETENTION_DAYS_OPTIONS.normalize(
        store.getSync(PreferencesConstants.KEY_RETENTION_DAYS, appSettings.retentionDays) as string);
      appSettings.remoteAutoSync = normalizeRemoteAutoSync(
        store.getSync(PreferencesConstants.KEY_REMOTE_AUTO_SYNC, appSettings.remoteAutoSync) as string);
      // 跨源去重：默认开启；老库没有这个 key 时读出来就是默认值。
      appSettings.dedupeEnabled =
        store.getSync(PreferencesConstants.KEY_DEDUPE_ENABLED, appSettings.dedupeEnabled) as boolean;
      // 通知策略：老库没有这些 key 时读出来就是默认值（免打扰 23:00–08:00 开、摘要关、无关键词）。
      const dndEnabledRaw: preferences.ValueType =
        store.getSync(PreferencesConstants.KEY_NOTIFY_DND_ENABLED, appSettings.notifyDndEnabled);
      appSettings.notifyDndEnabled =
        typeof dndEnabledRaw === 'boolean' ? dndEnabledRaw : NotifyDefaults.DND_ENABLED;
      appSettings.notifyDndStart = readMinuteOfDay(
        store.getSync(PreferencesConstants.KEY_NOTIFY_DND_START, appSettings.notifyDndStart),
        NotifyDefaults.DND_START);
      appSettings.notifyDndEnd = readMinuteOfDay(
        store.getSync(PreferencesConstants.KEY_NOTIFY_DND_END, appSettings.notifyDndEnd),
        NotifyDefaults.DND_END);
      const digestEnabledRaw: preferences.ValueType =
        store.getSync(PreferencesConstants.KEY_NOTIFY_DIGEST_ENABLED, appSettings.notifyDigestEnabled);
      appSettings.notifyDigestEnabled =
        typeof digestEnabledRaw === 'boolean' ? digestEnabledRaw : NotifyDefaults.DIGEST_ENABLED;
      appSettings.notifyDigestHour = readDigestHour(
        store.getSync(PreferencesConstants.KEY_NOTIFY_DIGEST_HOUR, appSettings.notifyDigestHour),
        NotifyDefaults.DIGEST_HOUR);
      appSettings.notifyKeywords = readKeywords(
        store.getSync(PreferencesConstants.KEY_NOTIFY_KEYWORDS, ''), appSettings.notifyKeywords);
      // 正文翻译：老库没有这些 key 时读出来就是默认值（关闭 / DeepL / 默认端点）。
      appSettings.translateEnabled =
        store.getSync(PreferencesConstants.KEY_TRANSLATE_ENABLED, appSettings.translateEnabled) as boolean;
      appSettings.translateProvider = normalizeProvider(
        store.getSync(PreferencesConstants.KEY_TRANSLATE_PROVIDER, appSettings.translateProvider) as string);
      appSettings.translateEndpoint =
        store.getSync(PreferencesConstants.KEY_TRANSLATE_ENDPOINT, appSettings.translateEndpoint) as string;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      console.error('SettingsStore.load failed: ' + error.code.toString());
    }
  }

  /**
   * 备份导出：只读取白名单键（与 BackupCodec.settingsWhitelist 一致）。
   * 用 switch 显式映射到 appSettings 字段，避免动态属性访问（ArkTS 严格模式）。
   */
  exportWhitelisted(): BackupSettings {
    const settings: BackupSettings = new BackupSettings();
    const keys: string[] = settingsWhitelist();
    for (let i = 0; i < keys.length; i += 1) {
      const key: string = keys[i];
      switch (key) {
        case PreferencesConstants.KEY_THEME_MODE:
          settings.set(key, appSettings.themeMode);
          break;
        case PreferencesConstants.KEY_LANGUAGE_MODE:
          settings.set(key, appSettings.languageMode);
          break;
        case PreferencesConstants.KEY_MATERIAL_TYPE:
          settings.set(key, appSettings.materialType);
          break;
        case PreferencesConstants.KEY_MATERIAL_LEVEL:
          settings.set(key, appSettings.materialLevel);
          break;
        case PreferencesConstants.KEY_BACKGROUND_KIND:
          settings.set(key, appSettings.backgroundKind);
          break;
        case PreferencesConstants.KEY_IMMERSIVE_ON:
          settings.set(key, appSettings.immersiveOn);
          break;
        case PreferencesConstants.KEY_POINT_LIGHT:
          settings.set(key, appSettings.pointLightEnabled);
          break;
        case PreferencesConstants.KEY_TITLE_BAR_SCROLL:
          settings.set(key, appSettings.titleBarScrollsWithContent);
          break;
        case PreferencesConstants.KEY_STATUS_BAR_SCROLL:
          settings.set(key, appSettings.statusBarScrollsWithContent);
          break;
        case PreferencesConstants.KEY_LOGO_KIND:
          settings.set(key, appSettings.logoKind);
          break;
        case PreferencesConstants.KEY_AUTO_REFRESH:
          settings.set(key, appSettings.autoRefresh);
          break;
        case PreferencesConstants.KEY_READER_KEEP_SCREEN_ON:
          settings.set(key, appSettings.readerKeepScreenOn);
          break;
        case PreferencesConstants.KEY_READER_FONT:
          settings.set(key, appSettings.readerFont);
          break;
        case PreferencesConstants.KEY_READER_FONT_SCALE:
          settings.set(key, appSettings.readerFontScale);
          break;
        case PreferencesConstants.KEY_READER_LINE_SCALE:
          settings.set(key, appSettings.readerLineScale);
          break;
        case PreferencesConstants.KEY_READER_LINE:
          settings.set(key, appSettings.readerLine);
          break;
        case PreferencesConstants.KEY_READER_FAMILY:
          settings.set(key, appSettings.readerFontFamily);
          break;
        case PreferencesConstants.KEY_READER_WIDTH:
          settings.set(key, appSettings.readerWidth);
          break;
        case PreferencesConstants.KEY_READER_ALIGN:
          settings.set(key, appSettings.readerAlign);
          break;
        case PreferencesConstants.KEY_READER_THEME:
          settings.set(key, appSettings.readerTheme);
          break;
        case PreferencesConstants.KEY_NOTIFY_NEW:
          settings.set(key, appSettings.notifyNewArticles);
          break;
        case PreferencesConstants.KEY_LIST_NEWEST_FIRST:
          settings.set(key, appSettings.listNewestFirst);
          break;
        case PreferencesConstants.KEY_LIST_GROUP_MODE:
          settings.set(key, appSettings.listGroupMode);
          break;
        case PreferencesConstants.KEY_HOME_FILTER:
          settings.set(key, appSettings.homeFilter);
          break;
        case PreferencesConstants.KEY_READER_VIEW_MODE:
          settings.set(key, appSettings.readerViewMode);
          break;
        case PreferencesConstants.KEY_ROW_LAYOUT:
          settings.set(key, appSettings.listRowLayout);
          break;
        case PreferencesConstants.KEY_SUMMARY_LINES:
          settings.set(key, appSettings.listSummaryLines);
          break;
        case PreferencesConstants.KEY_LIST_DENSITY:
          settings.set(key, appSettings.listDensity);
          break;
        case PreferencesConstants.KEY_ARCHIVE_RULE:
          settings.set(key, appSettings.archiveRule);
          break;
        case PreferencesConstants.KEY_DEDUPE_ENABLED:
          settings.set(key, appSettings.dedupeEnabled);
          break;
        case PreferencesConstants.KEY_REMOTE_AUTO_SYNC:
          settings.set(key, appSettings.remoteAutoSync);
          break;
        default:
          break;
      }
    }
    return settings;
  }

  /**
   * 备份恢复：仅白名单键生效（switch 显式写回 appSettings），随后 save()。
   * 主题 / 语言的运行期副作用（ThemeController / LocaleController）由 ViewModel 负责，
   * 这里只改状态与落盘。
   */
  applyWhitelisted(settings: BackupSettings): void {
    const keys: string[] = settingsWhitelist();
    for (let i = 0; i < keys.length; i += 1) {
      const key: string = keys[i];
      if (!settings.has(key)) {
        continue;
      }
      const value: BackupScalar | undefined = settings.get(key);
      switch (key) {
        case PreferencesConstants.KEY_THEME_MODE:
          appSettings.themeMode = THEME_OPTIONS.normalize(stringValue(value, appSettings.themeMode));
          break;
        case PreferencesConstants.KEY_LANGUAGE_MODE:
          appSettings.languageMode = LANGUAGE_OPTIONS.normalize(stringValue(value, appSettings.languageMode));
          break;
        case PreferencesConstants.KEY_MATERIAL_TYPE:
          appSettings.materialType = MATERIAL_TYPE_OPTIONS.normalize(stringValue(value, appSettings.materialType));
          break;
        case PreferencesConstants.KEY_MATERIAL_LEVEL:
          appSettings.materialLevel = MATERIAL_LEVEL_OPTIONS.normalize(stringValue(value, appSettings.materialLevel));
          break;
        case PreferencesConstants.KEY_BACKGROUND_KIND:
          appSettings.backgroundKind = BACKGROUND_OPTIONS.normalize(stringValue(value, appSettings.backgroundKind));
          break;
        case PreferencesConstants.KEY_IMMERSIVE_ON:
          appSettings.immersiveOn = booleanValue(value, appSettings.immersiveOn);
          break;
        case PreferencesConstants.KEY_POINT_LIGHT:
          appSettings.pointLightEnabled = booleanValue(value, appSettings.pointLightEnabled);
          break;
        case PreferencesConstants.KEY_TITLE_BAR_SCROLL:
          appSettings.titleBarScrollsWithContent = booleanValue(value, appSettings.titleBarScrollsWithContent);
          break;
        case PreferencesConstants.KEY_STATUS_BAR_SCROLL:
          appSettings.statusBarScrollsWithContent = booleanValue(value, appSettings.statusBarScrollsWithContent);
          break;
        case PreferencesConstants.KEY_LOGO_KIND:
          appSettings.logoKind = LOGO_OPTIONS.normalize(stringValue(value, appSettings.logoKind));
          break;
        case PreferencesConstants.KEY_AUTO_REFRESH:
          appSettings.autoRefresh = AUTO_REFRESH_OPTIONS.normalize(stringValue(value, appSettings.autoRefresh));
          break;
        case PreferencesConstants.KEY_READER_KEEP_SCREEN_ON:
          appSettings.readerKeepScreenOn = booleanValue(value, appSettings.readerKeepScreenOn);
          break;
        case PreferencesConstants.KEY_READER_FONT:
          appSettings.readerFont = READER_FONT_OPTIONS.normalize(stringValue(value, appSettings.readerFont));
          break;
        case PreferencesConstants.KEY_READER_FONT_SCALE:
          appSettings.readerFontScale = numberValue(value, appSettings.readerFontScale);
          break;
        case PreferencesConstants.KEY_READER_LINE_SCALE:
          appSettings.readerLineScale = numberValue(value, appSettings.readerLineScale);
          break;
        case PreferencesConstants.KEY_READER_LINE:
          appSettings.readerLine = READER_LINE_OPTIONS.normalize(stringValue(value, appSettings.readerLine));
          break;
        case PreferencesConstants.KEY_READER_FAMILY:
          appSettings.readerFontFamily = READER_FAMILY_OPTIONS.normalize(
            stringValue(value, appSettings.readerFontFamily));
          break;
        case PreferencesConstants.KEY_READER_WIDTH:
          appSettings.readerWidth = READER_WIDTH_OPTIONS.normalize(stringValue(value, appSettings.readerWidth));
          break;
        case PreferencesConstants.KEY_READER_ALIGN:
          appSettings.readerAlign = READER_ALIGN_OPTIONS.normalize(stringValue(value, appSettings.readerAlign));
          break;
        case PreferencesConstants.KEY_READER_THEME:
          appSettings.readerTheme = READER_THEME_OPTIONS.normalize(stringValue(value, appSettings.readerTheme));
          break;
        case PreferencesConstants.KEY_NOTIFY_NEW:
          appSettings.notifyNewArticles = booleanValue(value, appSettings.notifyNewArticles);
          break;
        case PreferencesConstants.KEY_LIST_NEWEST_FIRST:
          appSettings.listNewestFirst = booleanValue(value, appSettings.listNewestFirst);
          break;
        case PreferencesConstants.KEY_LIST_GROUP_MODE:
          appSettings.listGroupMode = stringValue(value, appSettings.listGroupMode);
          break;
        case PreferencesConstants.KEY_HOME_FILTER:
          appSettings.homeFilter = normalizeArticleFilter(stringValue(value, appSettings.homeFilter));
          break;
        case PreferencesConstants.KEY_READER_VIEW_MODE:
          appSettings.readerViewMode = normalizeReaderViewMode(
            stringValue(value, appSettings.readerViewMode));
          break;
        case PreferencesConstants.KEY_ROW_LAYOUT:
          appSettings.listRowLayout = ROW_LAYOUT_OPTIONS.normalize(stringValue(value, appSettings.listRowLayout));
          break;
        case PreferencesConstants.KEY_SUMMARY_LINES:
          appSettings.listSummaryLines = SUMMARY_LINES_OPTIONS.normalize(
            stringValue(value, appSettings.listSummaryLines));
          break;
        case PreferencesConstants.KEY_LIST_DENSITY:
          appSettings.listDensity = LIST_DENSITY_OPTIONS.normalize(stringValue(value, appSettings.listDensity));
          break;
        case PreferencesConstants.KEY_ARCHIVE_RULE:
          appSettings.archiveRule = ARCHIVE_OPTIONS.normalize(stringValue(value, appSettings.archiveRule));
          break;
        case PreferencesConstants.KEY_DEDUPE_ENABLED:
          appSettings.dedupeEnabled = booleanValue(value, appSettings.dedupeEnabled);
          break;
        case PreferencesConstants.KEY_REMOTE_AUTO_SYNC:
          appSettings.remoteAutoSync = normalizeRemoteAutoSync(
            stringValue(value, appSettings.remoteAutoSync));
          break;
        default:
          break;
      }
    }
    this.save();
  }

  /** 把当前 appSettings 全量写回。任何一次用户改动后调用。 */
  save(): void {
    // 通知策略先归一：越界分钟数 / 重复关键词不写回偏好库。
    appSettings.notifyDndStart = clampMinuteOfDay(appSettings.notifyDndStart, NotifyDefaults.DND_START);
    appSettings.notifyDndEnd = clampMinuteOfDay(appSettings.notifyDndEnd, NotifyDefaults.DND_END);
    appSettings.notifyDigestHour = clampDigestHour(appSettings.notifyDigestHour, NotifyDefaults.DIGEST_HOUR);
    appSettings.notifyKeywords = normalizeKeywords(appSettings.notifyKeywords);
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
      store.putSync(PreferencesConstants.KEY_RETENTION_MODE, appSettings.retentionMode);
      store.putSync(PreferencesConstants.KEY_RETENTION_DAYS, appSettings.retentionDays);
      store.putSync(PreferencesConstants.KEY_REMOTE_AUTO_SYNC, appSettings.remoteAutoSync);
      store.putSync(PreferencesConstants.KEY_DEDUPE_ENABLED, appSettings.dedupeEnabled);
      store.putSync(PreferencesConstants.KEY_NOTIFY_DND_ENABLED, appSettings.notifyDndEnabled);
      store.putSync(PreferencesConstants.KEY_NOTIFY_DND_START, appSettings.notifyDndStart);
      store.putSync(PreferencesConstants.KEY_NOTIFY_DND_END, appSettings.notifyDndEnd);
      store.putSync(PreferencesConstants.KEY_NOTIFY_DIGEST_ENABLED, appSettings.notifyDigestEnabled);
      store.putSync(PreferencesConstants.KEY_NOTIFY_DIGEST_HOUR, appSettings.notifyDigestHour);
      store.putSync(PreferencesConstants.KEY_NOTIFY_KEYWORDS, encodeKeywords(appSettings.notifyKeywords));
      store.putSync(PreferencesConstants.KEY_TRANSLATE_ENABLED, appSettings.translateEnabled);
      store.putSync(PreferencesConstants.KEY_TRANSLATE_PROVIDER, normalizeProvider(appSettings.translateProvider));
      store.putSync(PreferencesConstants.KEY_TRANSLATE_ENDPOINT, appSettings.translateEndpoint.trim());
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
