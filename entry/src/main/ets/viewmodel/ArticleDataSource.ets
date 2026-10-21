/*
 * ArticleDataSource.ets — 文章列表的 LazyForEach 数据源（纯 V2 场景下的 IDataSource 实现）。
 *
 * 为什么需要它：List + ForEach 会把所有条目一次性构建出来，条数一多就吃内存、滚动掉帧；
 * LazyForEach + IDataSource 只构建可见区域附近的条目。
 *
 * 与 ViewModel 的分工：ViewModel 负责「筛选 + 排序 + 分页」（articles / articlesTotal），
 * 这里只做「把最新的数组同步进来 + 通知列表刷新」，不持有业务逻辑。
 */

import { Article } from '../model/Feed';

/**
 * LazyForEach 的行键值。
 *
 * LazyForEach 只按键值判断是否重建子组件：键不变时即使数据源通知了刷新，也会复用旧节点、
 * 不再读取新的属性 —— 已读 / 收藏这类「原地改对象字段」的状态就永远不更新。
 * 因此把会影响行渲染的可变字段并入键值（id 保持稳定身份）。
 */
export function articleRowKey(item: Article): string {
  return item.id + '_' + (item.read ? '1' : '0') + '_' + (item.starred ? '1' : '0') +
    '_' + Math.round(item.progressRatio * 100);
}

/** 列表数据源：持有一份不可变数组，替换时通知刷新。 */
export class ArticleDataSource implements IDataSource {
  private items: object[] = [];
  private listeners: DataChangeListener[] = [];

  /** 用新数组整体替换（列表会重新按需构建可见项）。 */
  setItems(next: object[]): void {
    this.items = next;
    for (let i = 0; i < this.listeners.length; i += 1) {
      this.listeners[i].onDataReloaded();
    }
  }

  /** 数据源是否已经是同一批内容（按引用比较），避免重复刷新。 */
  isSame(next: object[]): boolean {
    if (this.items.length !== next.length) {
      return false;
    }
    for (let i = 0; i < next.length; i += 1) {
      if (this.items[i] !== next[i]) {
        return false;
      }
    }
    return true;
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): object {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }
}

/**
 * 分组视图里的一组文章。
 *
 * 每组自带一个数据源，这样列表可以用「ListItemGroup + LazyForEach」组织：
 * 组头由 ListItemGroup 的 header 承载，组内条目仍然虚拟化。
 */
export class ArticleGroup {
  /** 组标识（订阅源 id 或日期桶 key）。 */
  readonly key: string;
  /** 组标题（订阅源名，或「今天」「昨天」等）。 */
  readonly title: ResourceStr;
  /** 组内未读数。 */
  readonly unread: number;
  /** 组内条目总数。 */
  readonly total: number;
  /** 组内条目的数据源。 */
  readonly source: ArticleDataSource;

  constructor(key: string, title: ResourceStr, unread: number, total: number, source: ArticleDataSource) {
    this.key = key;
    this.title = title;
    this.unread = unread;
    this.total = total;
    this.source = source;
  }
}
