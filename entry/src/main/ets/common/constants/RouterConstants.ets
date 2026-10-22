/*
 * RouterConstants.ets — 路由名常量，消除魔法字符串。
 *
 * 单模块内用 NavPathStack + @Builder 映射即可；跨模块跳转时应改用系统路由表
 * （module.json5 的 routerMap + resources/base/profile/route_map.json）。
 */
export class RouterConstants {
  /** 文章详情页。 */
  static readonly PAGE_ARTICLE: string = 'article';
  /** 单个订阅源的文章列表页。 */
  static readonly PAGE_FEED_ARTICLES: string = 'feedArticles';
  /** 标注聚合页（全部标注 + 导出）。 */
  static readonly PAGE_HIGHLIGHTS: string = 'highlights';
  /** 点光源效果预览页。 */
  static readonly PAGE_EFFECT: string = 'effect';
  /** 全局全文检索页。 */
  static readonly PAGE_SEARCH: string = 'search';
  /** 存储与保留页。 */
  static readonly PAGE_STORAGE: string = 'storage';
  /** 单源设置页。 */
  static readonly PAGE_FEED_SETTINGS: string = 'feedSettings';
  /** 标签管理页（多选 AND 筛选）。 */
  static readonly PAGE_TAGS: string = 'tags';
  /** 单个标签（或多标签 AND）下的文章列表页。 */
  static readonly PAGE_TAG_ARTICLES: string = 'tagArticles';
  /** 智能文件夹管理页。 */
  static readonly PAGE_SMART_FOLDERS: string = 'smartFolders';
  /** 远端账号与服务页（FrashRSS / GReader API）。 */
  static readonly PAGE_REMOTE: string = 'remoteService';
}
