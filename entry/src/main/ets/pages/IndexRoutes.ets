/* Purpose-specific navigation destinations for the application shell. */
import { DynamicHideParams, HdsNavDestination, HdsNavDestinationTitleMode,
  HdsNavigationTitleBarOptions } from '@kit.UIDesignKit';
import { RouterConstants } from '../common/constants/RouterConstants';
import { UrlText } from '../common/utils/UrlText';
import { ResponsiveContent } from '../views/ResponsiveContent';
import { ArticleDetailView } from '../views/ArticleDetailView';
import { LinkedWebView } from '../views/LinkedWebView';
import { FeedArticlesView } from '../views/FeedArticlesView';
import { HighlightsView } from '../views/HighlightsView';
import { EffectPreviewView } from '../views/EffectPreviewView';
import { SearchView } from '../views/SearchView';
import { StorageView } from '../views/StorageView';
import { SettingsLookView } from '../views/settings/SettingsLookView';
import { SettingsMaterialView } from '../views/settings/SettingsMaterialView';
import { SettingsReadingView } from '../views/settings/SettingsReadingView';
import { SettingsFeedView } from '../views/settings/SettingsFeedView';
import { SettingsSystemView } from '../views/settings/SettingsSystemView';
import { BackupView } from '../views/BackupView';
import { FeedSettingsView } from '../views/FeedSettingsView';
import { TagsView } from '../views/TagsView';
import { TagArticlesView } from '../views/TagArticlesView';
import { SmartFoldersView } from '../views/SmartFoldersView';
import { RulesView } from '../views/RulesView';
import { RuleEditView } from '../views/RuleEditView';
import { HiddenArticlesView } from '../views/HiddenArticlesView';
import { SyncView } from '../views/SyncView';
import { RemoteServiceView } from '../views/RemoteServiceView';
import { RemoteMigrationView } from '../views/RemoteMigrationView';
import { ShareSettingsView } from '../views/ShareSettingsView';
import { NotifySettingsView } from '../views/NotifySettingsView';
import { TranslateSettingsView } from '../views/TranslateSettingsView';
import { PrivacyView } from '../views/PrivacyView';
import { DiscoverView } from '../views/DiscoverView';
import { DiagnosticsView } from '../views/DiagnosticsView';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { IndexRouteScrollers } from './IndexRouteScrollers';

export interface IndexRouteContext {
  navPathStack: NavPathStack;
  scrollers: IndexRouteScrollers;
  titleOptions: (title: ResourceStr) => HdsNavigationTitleBarOptions;
  articleTitleOptions: () => HdsNavigationTitleBarOptions;
  dynamicHideParams: () => DynamicHideParams;
}

@Builder
export function indexPageMap(name: string, pageInfos: Object, config: IndexRouteContext) {
    if (name === RouterConstants.PAGE_ARTICLE) {
      HdsNavDestination() {
        ArticleDetailView({
          scroller: config.scrollers.articleScroller,
          navPathStack: config.navPathStack
        })
      }
      // 标题栏为 HDS 原生（系统返回键 + 标题文字），背板常显（见 articleTitleOptions）：
      // 正文滚动发生在 ArkWeb 内部，跟手渐变等不到触发时机，固定背板才能保证标题可读。
      .titleBar(config.articleTitleOptions())
      .titleMode(HdsNavDestinationTitleMode.MINI)
      // 不透明背板：原生覆盖式 push 时不会透过新页看到上一页，也不再因淡出透出壁纸。
      .backgroundColor($r('app.color.hm_web_surface'))
      // 标题栏显隐与其它页同一机制（跟随滚动 + 两个设置）。正文模式滚动挂在 articleScroller 上能跟到；
      // 网页原文由 ArkWeb 自己滚动、不出现在 Scroller 偏移里，那种情况下标题栏保持常驻。
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.articleScroller])
    } else if (name === RouterConstants.PAGE_LINKED_WEB) {
      HdsNavDestination() {
        LinkedWebView({ initialUrl: pageInfos as string })
      }
      .titleBar(config.titleOptions(UrlText.host(pageInfos as string)))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
    } else if (name === RouterConstants.PAGE_FEED_ARTICLES) {
      HdsNavDestination() {
        ResponsiveContent() {
          FeedArticlesView({ navPathStack: config.navPathStack, scroller: config.scrollers.feedArticlesScroller })
        }
      }
      .titleBar(config.titleOptions(feedViewModel.detailFeedTitle.length > 0
        ? feedViewModel.detailFeedTitle
        : $r('app.string.feed_articles_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      // 不透明背板：与详情页一致，走系统原生转场不穿透。
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.feedArticlesScroller])
    } else if (name === RouterConstants.PAGE_HIGHLIGHTS) {
      HdsNavDestination() {
        ResponsiveContent() {
          HighlightsView({ navPathStack: config.navPathStack, scroller: config.scrollers.highlightsScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.hl_library_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      // 不透明背板：与详情页一致，走系统原生转场不穿透。
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.highlightsScroller])
    } else if (name === RouterConstants.PAGE_EFFECT) {
      HdsNavDestination() {
        EffectPreviewView()
      }
      .titleBar(config.titleOptions($r('app.string.effect_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      // 不透明背板：与详情页一致，走系统原生转场不穿透。
      .backgroundColor($r('app.color.hm_web_surface'))
    } else if (name === RouterConstants.PAGE_SEARCH) {
      HdsNavDestination() {
        ResponsiveContent() {
          SearchView({ navPathStack: config.navPathStack, scroller: config.scrollers.searchScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.search_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.searchScroller])
    } else if (name === RouterConstants.PAGE_STORAGE) {
      HdsNavDestination() {
        ResponsiveContent() {
          StorageView({ navPathStack: config.navPathStack, scroller: config.scrollers.storageScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.storage_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.storageScroller])
    } else if (name === RouterConstants.PAGE_SETTINGS_LOOK) {
      HdsNavDestination() {
        ResponsiveContent() {
          SettingsLookView({ navPathStack: config.navPathStack, scroller: config.scrollers.settingsLookScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.settings_entry_look')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.settingsLookScroller])
    } else if (name === RouterConstants.PAGE_SETTINGS_MATERIAL) {
      HdsNavDestination() {
        ResponsiveContent() {
          SettingsMaterialView({ navPathStack: config.navPathStack, scroller: config.scrollers.settingsMaterialScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.settings_entry_material')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.settingsMaterialScroller])
    } else if (name === RouterConstants.PAGE_SETTINGS_READING) {
      HdsNavDestination() {
        ResponsiveContent() {
          SettingsReadingView({ navPathStack: config.navPathStack, scroller: config.scrollers.settingsReadingScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.settings_entry_reading')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.settingsReadingScroller])
    } else if (name === RouterConstants.PAGE_SETTINGS_FEED) {
      HdsNavDestination() {
        ResponsiveContent() {
          SettingsFeedView({ navPathStack: config.navPathStack, scroller: config.scrollers.settingsFeedScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.settings_entry_feed')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.settingsFeedScroller])
    } else if (name === RouterConstants.PAGE_SETTINGS_SYSTEM) {
      HdsNavDestination() {
        ResponsiveContent() {
          SettingsSystemView({ navPathStack: config.navPathStack, scroller: config.scrollers.settingsSystemScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.settings_entry_system')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.settingsSystemScroller])
    } else if (name === RouterConstants.PAGE_BACKUP) {
      HdsNavDestination() {
        ResponsiveContent() {
          BackupView({ navPathStack: config.navPathStack, scroller: config.scrollers.backupScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.backup_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.backupScroller])
    } else if (name === RouterConstants.PAGE_FEED_SETTINGS) {
      HdsNavDestination() {
        ResponsiveContent() {
          FeedSettingsView({ navPathStack: config.navPathStack, scroller: config.scrollers.feedSettingsScroller })
        }
      }
      .titleBar(config.titleOptions(feedViewModel.settingsFeedTitle()))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.feedSettingsScroller])
    } else if (name === RouterConstants.PAGE_TAGS) {
      HdsNavDestination() {
        ResponsiveContent() {
          TagsView({ navPathStack: config.navPathStack, scroller: config.scrollers.tagsScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.tag_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.tagsScroller])
    } else if (name === RouterConstants.PAGE_TAG_ARTICLES) {
      HdsNavDestination() {
        ResponsiveContent() {
          TagArticlesView({ navPathStack: config.navPathStack, scroller: config.scrollers.tagArticlesScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.tag_articles_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.tagArticlesScroller])
    } else if (name === RouterConstants.PAGE_SMART_FOLDERS) {
      HdsNavDestination() {
        ResponsiveContent() {
          SmartFoldersView({ navPathStack: config.navPathStack, scroller: config.scrollers.smartFoldersScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.smart_folder_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.smartFoldersScroller])
    } else if (name === RouterConstants.PAGE_RULES) {
      HdsNavDestination() {
        ResponsiveContent() {
          RulesView({ navPathStack: config.navPathStack, scroller: config.scrollers.rulesScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.rule_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.rulesScroller])
    } else if (name === RouterConstants.PAGE_RULE_EDIT) {
      HdsNavDestination() {
        ResponsiveContent() {
          RuleEditView({ navPathStack: config.navPathStack, scroller: config.scrollers.ruleEditScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.rule_edit_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.ruleEditScroller])
    } else if (name === RouterConstants.PAGE_HIDDEN) {
      HdsNavDestination() {
        ResponsiveContent() {
          HiddenArticlesView({ navPathStack: config.navPathStack, scroller: config.scrollers.hiddenScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.hidden_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.hiddenScroller])
    } else if (name === RouterConstants.PAGE_SYNC) {
      HdsNavDestination() {
        ResponsiveContent() {
          SyncView({ navPathStack: config.navPathStack, scroller: config.scrollers.syncScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.sync_entry_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.syncScroller])
    } else if (name === RouterConstants.PAGE_REMOTE) {
      HdsNavDestination() {
        ResponsiveContent() {
          RemoteServiceView({ navPathStack: config.navPathStack, scroller: config.scrollers.remoteScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.remote_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.remoteScroller])
    } else if (name === RouterConstants.PAGE_REMOTE_MIGRATION) {
      HdsNavDestination() {
        ResponsiveContent() {
          RemoteMigrationView({ navPathStack: config.navPathStack, scroller: config.scrollers.remoteMigrationScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.remote_migration_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.remoteMigrationScroller])
    } else if (name === RouterConstants.PAGE_SHARE_SETTINGS) {
      HdsNavDestination() {
        ResponsiveContent() {
          ShareSettingsView({ navPathStack: config.navPathStack, scroller: config.scrollers.shareSettingsScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.share_settings_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.shareSettingsScroller])
    } else if (name === RouterConstants.PAGE_NOTIFY_SETTINGS) {
      HdsNavDestination() {
        ResponsiveContent() {
          NotifySettingsView({ navPathStack: config.navPathStack, scroller: config.scrollers.notifySettingsScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.notify_settings_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.notifySettingsScroller])
    } else if (name === RouterConstants.PAGE_TRANSLATE_SETTINGS) {
      HdsNavDestination() {
        ResponsiveContent() {
          TranslateSettingsView({ navPathStack: config.navPathStack, scroller: config.scrollers.translateSettingsScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.translate_settings_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.translateSettingsScroller])
    } else if (name === RouterConstants.PAGE_PRIVACY) {
      HdsNavDestination() {
        ResponsiveContent() {
          PrivacyView({ navPathStack: config.navPathStack, scroller: config.scrollers.privacyScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.privacy_settings_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.privacyScroller])
    } else if (name === RouterConstants.PAGE_DISCOVER) {
      HdsNavDestination() {
        ResponsiveContent() {
          DiscoverView({ scroller: config.scrollers.discoverScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.discover_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.discoverScroller])
    } else if (name === RouterConstants.PAGE_DIAGNOSTICS) {
      HdsNavDestination() {
        ResponsiveContent() {
          DiagnosticsView({ navPathStack: config.navPathStack, scroller: config.scrollers.diagnosticsScroller })
        }
      }
      .titleBar(config.titleOptions($r('app.string.diagnostics_title')))
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .backgroundColor($r('app.color.hm_web_surface'))
      .dynamicHideTitleBar(config.dynamicHideParams())
      .bindToScrollable([config.scrollers.diagnosticsScroller])
    }
}
