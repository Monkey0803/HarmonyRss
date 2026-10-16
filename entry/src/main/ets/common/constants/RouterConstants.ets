/*
 * RouterConstants.ets — 路由名常量，消除魔法字符串。
 *
 * 单模块内用 NavPathStack + @Builder 映射即可；跨模块跳转时应改用系统路由表
 * （module.json5 的 routerMap + resources/base/profile/route_map.json）。
 */
export class RouterConstants {
  /** 文章详情页。 */
  static readonly PAGE_ARTICLE: string = 'article';
  /** 订阅源管理页。 */
  static readonly PAGE_SUBSCRIPTIONS: string = 'subscriptions';
  /** 点光源效果预览页。 */
  static readonly PAGE_EFFECT: string = 'effect';
}
