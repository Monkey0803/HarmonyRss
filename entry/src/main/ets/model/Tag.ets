/*
 * Tag.ets — 标签与智能文件夹的领域模型（ArkUI 状态管理 V2）。
 *
 * 标签（Tag）与文章是多对多：模型只携带「名称 + 关联文章数」，计数由 SQL 派生，不单独存。
 * 智能文件夹（SmartFolder）只存用户输入的检索语法原始串，打开时交给现有搜索链路执行。
 */

/** 一个标签 + 关联文章数（列表 / 详情 chips 共用）。 */
@ObservedV2
export class TagWithCount {
  readonly id: string;
  /** 展示名（已归一：去首尾空白、连续空白折叠、≤32 字符）。 */
  @Trace name: string;
  /** 关联文章数（JOIN articles 后统计，已删除 / 在回收站的文章不计入）。 */
  @Trace count: number;
  /** 创建时间（毫秒）。 */
  readonly createdAt: number;

  constructor(id: string, name: string, count: number, createdAt: number) {
    this.id = id;
    this.name = name;
    this.count = count;
    this.createdAt = createdAt;
  }
}

/** 一个智能文件夹：名称 + 检索语法原始串 + 手动排序位。 */
@ObservedV2
export class SmartFolder {
  readonly id: string;
  @Trace name: string;
  /** 检索语法原始串（关键词 / from: / is: / after: / before: / 引号短语）。 */
  @Trace query: string;
  /** 手动排序位（越小越靠前）。 */
  @Trace sortOrder: number;
  readonly createdAt: number;
  @Trace updatedAt: number;

  constructor(id: string, name: string, query: string, sortOrder: number,
    createdAt: number, updatedAt: number) {
    this.id = id;
    this.name = name;
    this.query = query;
    this.sortOrder = sortOrder;
    this.createdAt = createdAt;
    this.updatedAt = updatedAt;
  }
}
