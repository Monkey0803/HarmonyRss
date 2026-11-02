/**
 * AppMenu.ets — 全工程共用的下拉菜单（bindMenu）渲染入口，纯状态管理 V2。
 *
 * 视觉基线：设置页「外观与语言」的主题下拉（参考图 2）——圆角卡片、48vp 行高、
 * 选中项铺满行宽的品牌色高亮块 + 品牌色文案、只有多分区菜单才出现分隔线。
 * 改造前首页排序菜单（图 1）自绘的行是「8vp 圆角 + 左右内缩的小方块」，且两组设置
 * 共用一个平铺菜单导致两行同时高亮，这里一并收口。
 *
 * 为什么用全局 @Builder 而不是自定义组件：
 *   - 菜单内容纯展示、无生命周期需求（CodeLinter @performance/avoid-overusing-custom-component-check）；
 *   - Menu / MenuItem 本身只能作为 builder 内容挂在 bindMenu 上。
 *
 * 四个踩过的坑（别改回去）：
 *   1) @Builder 传两个及以上参数时不随状态刷新 —— 这里每个 builder 只收一个参数；
 *   2) MenuItem 内自定义内容的父高度不可用，行高必须给固定值（menu_item_height），
 *      否则菜单会被撑成一条超出屏幕的长面板（只剩第一项可见）；
 *   3) MenuItem 上挂的 onClick 不触发，点击必须挂在行内容上；
 *   4) 菜单内容在打开时重建，所以 spec 要在调用方的 builder 里现算，不要缓存。
 */

import { LengthMetrics } from '@kit.ArkUI';
import { MenuItemSpec, MenuSectionSpec, MenuSpec } from './MenuSpec';

/** 分组分隔线左右缩进（与行内边距一致），LengthMetrics 不接受资源引用。 */
const DIVIDER_INSET: LengthMetrics = LengthMetrics.vp(12);

/** 菜单项文案色：选中 → 品牌色；危险动作 → 危险色；其余主文本色。 */
function itemColor(item: MenuItemSpec): ResourceColor {
  if (item.selected) {
    return $r('app.color.hm_brand');
  }
  return item.danger ? $r('app.color.hm_danger') : $r('app.color.hm_text_primary');
}

/** 前置图标色：与文案同一套语义（选中品牌色 / 危险色 / 主文本色）。 */
function iconColor(item: MenuItemSpec): ResourceColor {
  return itemColor(item);
}

/** 一条菜单项的内容行（单参 @Builder）。 */
@Builder
function MenuRow(item: MenuItemSpec) {
  Stack() {
    Row({ space: $r('app.float.space_s') }) {
      if (item.icon !== undefined) {
        SymbolGlyph(item.icon)
          .fontSize($r('app.float.icon_size'))
          .fontColor([iconColor(item)])
      }
      Text(item.label)
        .fontSize($r('app.float.font_size_body'))
        .fontWeight(item.selected ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(itemColor(item))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ left: $r('app.float.space_m'), right: $r('app.float.space_m') })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(item.selected
      ? $r('app.color.hm_menu_item_selected')
      : $r('app.color.hm_page_transparent'))
    // 高亮块铺满行宽、圆角略小于卡片（卡片 20 / 块 16）—— 不再叠 margin：
    // 100% 宽度加外边距会在右侧溢出，左右留白不对称（旧 FeedSettingsView 注释记录过）。
    .borderRadius($r('app.float.radius_card'))
  }
  .width('100%')
  .height($r('app.float.menu_item_height'))
  .onClick(() => {
    if (item.enabled) {
      item.action();
    }
  })
}

/** 分区内的一组菜单项。 */
@Builder
function MenuRows(section: MenuSectionSpec) {
  ForEach(section.items, (item: MenuItemSpec) => {
    MenuItem(MenuRow(item))
      // .enabled 留在 MenuItem 上：禁用项既置灰，也不会因为点击关闭菜单。
      .enabled(item.enabled)
      .accessibilityChecked(item.selected)
  }, (item: MenuItemSpec) => item.key())
}

/**
 * 一张下拉菜单。调用方在自己的 @Builder 里现算 spec，再挂到 bindMenu：
 *
 *   @Builder
 *   SortMenu() {
 *     AppMenu(this.sortMenuSpec());
 *   }
 *   ...
 *   .bindMenu(this.SortMenu(),
 *     MaterialController.menuOptions({ placement: Placement.BottomRight }, appSettings.immersiveOn))
 */
@Builder
export function AppMenu(spec: MenuSpec) {
  Menu() {
    // 单分区且无小标题：直接铺 MenuItem，不画分组分隔线（绝大多数动作菜单）。
    if (spec.sections.length === 1 && spec.sections[0].header === undefined) {
      MenuRows(spec.sections[0])
    } else {
      // 多分区（或带小标题）：每个分区一个 MenuItemGroup，分隔线统一成 hm_divider。
      ForEach(spec.sections, (section: MenuSectionSpec) => {
        MenuItemGroup({ header: section.header }) {
          MenuRows(section)
        }
      }, (section: MenuSectionSpec, index: number) => index.toString())
    }
  }
  .width(spec.width === undefined ? $r('app.float.menu_width') : spec.width)
  .radius($r('app.float.radius_menu'))
  .menuItemGroupDivider({
    color: $r('app.color.hm_divider'),
    startMargin: DIVIDER_INSET,
    endMargin: DIVIDER_INSET
  })
}
