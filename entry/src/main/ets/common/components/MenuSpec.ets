/*
 * MenuSpec.ets — 下拉菜单的数据模型（纯数据，不依赖 ArkUI 渲染，可在 ohosTest 直接测）。
 *
 * 背景：改造前全工程有 14 处 bindMenu，写法分三类：
 *   - 设置/存储/订阅设置三处各写了一遍「圆角高亮行 + Divider」菜单（几乎逐字重复）；
 *   - 阅读页排序菜单自绘行，两组设置共用一个平铺菜单 → 两行同时高亮（图 1）；
 *   - 其余 8 处直接吃系统 MenuItem，其中 5 处连宽度都没设，会弹成系统「两列宽」。
 * 统一成规格对象后，渲染只在 common/components/AppMenu.ets 里发生，调用点只描述
 * 「有哪些项、哪些项当前选中、点了做什么」。
 *
 * id 必须在一张菜单内唯一（AppMenu 用它做 ForEach key）：重复键会导致菜单项丢失或点击错位。
 * 动态项（分组名等）调用方必须加前缀，例如 'group:' + name。
 */

/** 一条菜单项。 */
export class MenuItemSpec {
  /** 菜单内唯一 id（ForEach key）；动态项记得加前缀。 */
  readonly id: string;
  /** 展示文案（可带占位符）。 */
  readonly label: ResourceStr;
  /** 选中后执行的动作，菜单随之关闭。 */
  readonly action: () => void;
  /** 前置 HM Symbol 图标；无图标为 undefined。 */
  icon: Resource | undefined = undefined;
  /** 是否当前选中项（品牌色高亮块 + 品牌色文案）。 */
  selected: boolean = false;
  /** 危险动作（删除 / 清空）：文案与图标用危险色。 */
  danger: boolean = false;
  /** 是否可用；false 时置灰、点击无效且菜单不关闭。 */
  enabled: boolean = true;

  constructor(id: string, label: ResourceStr, action: () => void) {
    this.id = id;
    this.label = label;
    this.action = action;
  }

  /** 前置 HM Symbol 图标。 */
  withIcon(icon: Resource): MenuItemSpec {
    this.icon = icon;
    return this;
  }

  /** 标记为当前选中项。 */
  markSelected(): MenuItemSpec {
    this.selected = true;
    return this;
  }

  /** 标记为危险动作（删除 / 清空）。 */
  markDanger(): MenuItemSpec {
    this.danger = true;
    return this;
  }

  /** 设置可用态（繁忙时置灰的项）。 */
  withEnabled(enabled: boolean): MenuItemSpec {
    this.enabled = enabled;
    return this;
  }

  /** ForEach 的键。 */
  key(): string {
    return this.id;
  }
}

/**
 * 一个分区：可带小标题。
 *
 * 无标题的分区只靠 MenuItemGroup 的默认分隔线区分（例如「未分组 / 各分组」与「新建分组」）；
 * 有标题的分区用于一张菜单里含两组**各自独立选中**的设置（首页排序 / 分组）。
 */
export class MenuSectionSpec {
  readonly items: MenuItemSpec[];
  readonly header: ResourceStr | undefined;

  constructor(items: MenuItemSpec[], header?: ResourceStr) {
    this.items = items;
    this.header = header;
  }
}

/** 一张菜单。 */
export class MenuSpec {
  readonly sections: MenuSectionSpec[];
  /** 菜单宽度；undefined 时用 app.float.menu_width。 */
  readonly width: Length | undefined;

  constructor(sections: MenuSectionSpec[], width?: Length) {
    this.sections = sections;
    this.width = width;
  }

  /** 单分区菜单（最常见的动作菜单）。 */
  static fromItems(items: MenuItemSpec[]): MenuSpec {
    return new MenuSpec([new MenuSectionSpec(items)]);
  }

  /** 多分区菜单（分区分隔线；header 可缺省）。 */
  static fromSections(sections: MenuSectionSpec[]): MenuSpec {
    return new MenuSpec(sections);
  }

  /** 第一处被选中的 id；无选中返回空串（设置行回填文案 / 单测断言都靠它）。 */
  firstSelectedId(): string {
    for (let i = 0; i < this.sections.length; i += 1) {
      const items: MenuItemSpec[] = this.sections[i].items;
      for (let j = 0; j < items.length; j += 1) {
        if (items[j].selected) {
          return items[j].id;
        }
      }
    }
    return '';
  }
}
