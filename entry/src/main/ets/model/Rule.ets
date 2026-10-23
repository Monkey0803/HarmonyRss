/*
 * Rule.ets — 本地规则引擎的领域模型。
 *
 * 规则 = 名称 + 启用 + 优先级 + 关键词（同一规则内 AND）+ 匹配字段（多选）
 *        + 来源范围（全部 / 指定源）+ 动作（已读 / 收藏 / 打标签 / 隐藏）+ 标签集合。
 *
 * 设计要点：
 *   - 字段 / 动作用字符串常量类而不是 enum：落库是逗号串，跨层比较时不需要 enum ↔ string 转换；
 *   - Rule 用 @ObservedV2 + @Trace：规则页里改启用 / 优先级 / 命中统计后界面自动刷新；
 *   - RuleDraft 是编辑态的纯数据（不参与观察），由 ViewModel 组装后交给 RuleStore 落库。
 */

/** 匹配字段（可多选）。 */
export class RuleField {
  static readonly TITLE: string = 'title';
  static readonly SUMMARY: string = 'summary';
  static readonly CONTENT: string = 'content';
  static readonly AUTHOR: string = 'author';

  /** 全部字段（编辑页 chips 顺序）。 */
  static all(): string[] {
    return [RuleField.TITLE, RuleField.SUMMARY, RuleField.CONTENT, RuleField.AUTHOR];
  }

  /** 是否为已知字段（脏值 / 旧数据容错）。 */
  static isValid(value: string): boolean {
    return value === RuleField.TITLE || value === RuleField.SUMMARY ||
      value === RuleField.CONTENT || value === RuleField.AUTHOR;
  }
}

/** 命中后的动作（可多选，动作只增不减）。 */
export class RuleAction {
  static readonly READ: string = 'read';
  static readonly STAR: string = 'star';
  static readonly TAG: string = 'tag';
  static readonly HIDE: string = 'hide';

  /** 全部动作（编辑页 chips 顺序）。 */
  static all(): string[] {
    return [RuleAction.READ, RuleAction.STAR, RuleAction.TAG, RuleAction.HIDE];
  }

  /** 是否为已知动作。 */
  static isValid(value: string): boolean {
    return value === RuleAction.READ || value === RuleAction.STAR ||
      value === RuleAction.TAG || value === RuleAction.HIDE;
  }
}

/** 规则校验结果码（视图据此映射文案）。用字符串常量而非 enum：跨层比较最简单。 */
export class RuleError {
  static readonly NONE: string = 'none';
  /** 名称为空。 */
  static readonly NAME_EMPTY: string = 'nameEmpty';
  /** 名称超长（>32）。 */
  static readonly NAME_TOO_LONG: string = 'nameTooLong';
  /** 没有任何关键词。 */
  static readonly KEYWORDS_EMPTY: string = 'keywordsEmpty';
  /** 关键词超过单条规则上限。 */
  static readonly KEYWORDS_TOO_MANY: string = 'keywordsTooMany';
  /** 没有选择任何匹配字段。 */
  static readonly FIELDS_EMPTY: string = 'fieldsEmpty';
  /** 没有选择任何动作。 */
  static readonly ACTIONS_EMPTY: string = 'actionsEmpty';
  /** 选择了「打标签」但没有选择任何标签。 */
  static readonly TAGS_EMPTY: string = 'tagsEmpty';
  /** 规则数量已达上限。 */
  static readonly LIMIT_REACHED: string = 'limitReached';
}

/** 一条规则（持久化实体 + 命中统计）。 */
@ObservedV2
export class Rule {
  /** 唯一标识：rule_<ts>_<rand>。 */
  id: string;
  @Trace name: string;
  @Trace enabled: boolean;
  /** 优先级：越小越先执行（0 起连续）。 */
  @Trace priority: number;
  /** 关键词（同一规则内 AND；非空）。 */
  @Trace keywords: string[];
  /** 匹配字段（RuleField 常量集合）。 */
  @Trace fields: string[];
  /** 来源范围：空数组 = 全部来源，否则只匹配这些订阅源。 */
  @Trace feedIds: string[];
  /** 动作集合（RuleAction 常量集合）。 */
  @Trace actions: string[];
  /** 打标签动作使用的标签 id。 */
  @Trace tagIds: string[];
  /** 累计命中篇数。 */
  @Trace matchCount: number;
  /** 最后命中时间（毫秒）；0 表示从未命中。 */
  @Trace lastHitAt: number;

  constructor(id: string, name: string, enabled: boolean, priority: number,
    keywords: string[], fields: string[], feedIds: string[], actions: string[],
    tagIds: string[], matchCount: number = 0, lastHitAt: number = 0) {
    this.id = id;
    this.name = name;
    this.enabled = enabled;
    this.priority = priority;
    this.keywords = keywords;
    this.fields = fields;
    this.feedIds = feedIds;
    this.actions = actions;
    this.tagIds = tagIds;
    this.matchCount = matchCount;
    this.lastHitAt = lastHitAt;
  }

  /** 是否包含某个动作。 */
  hasAction(action: string): boolean {
    return this.actions.indexOf(action) >= 0;
  }
}

/** 编辑态（不含命中统计）。 */
export class RuleDraft {
  name: string;
  enabled: boolean;
  keywords: string[];
  fields: string[];
  feedIds: string[];
  actions: string[];
  tagIds: string[];

  constructor(name: string, enabled: boolean, keywords: string[], fields: string[],
    feedIds: string[], actions: string[], tagIds: string[]) {
    this.name = name;
    this.enabled = enabled;
    this.keywords = keywords;
    this.fields = fields;
    this.feedIds = feedIds;
    this.actions = actions;
    this.tagIds = tagIds;
  }
}

/** 由已保存的规则生成编辑态草稿（编辑页预填用）。 */
export function draftOf(rule: Rule): RuleDraft {
  return new RuleDraft(rule.name, rule.enabled, rule.keywords.slice(), rule.fields.slice(),
    rule.feedIds.slice(), rule.actions.slice(), rule.tagIds.slice());
}

/** 试运行结果：扫描条数 + 命中条数（零副作用）。 */
export class RuleTestResult {
  readonly scanned: number;
  readonly matched: number;

  constructor(scanned: number, matched: number) {
    this.scanned = scanned;
    this.matched = matched;
  }
}

/**
 * 规则执行计划（RuleEngine.plan 的纯函数结果）。
 *
 * - readIds / starredIds / hiddenIds：需要置位的文章 id（已去重）；
 * - tagHits：标签 id → 需要打标的文章 id（tagIds 保序，避免遍历 Map）；
 * - ruleHits：规则 id → 本批实际命中的篇数（ruleIds 保序）。
 */
export class RulePlan {
  readonly readIds: string[];
  readonly starredIds: string[];
  readonly hiddenIds: string[];
  readonly tagIds: string[];
  readonly tagHits: Map<string, string[]>;
  readonly ruleIds: string[];
  readonly ruleHits: Map<string, number>;
  /** 命中任意规则的文章篇数。 */
  readonly matched: number;

  constructor(readIds: string[], starredIds: string[], hiddenIds: string[],
    tagIds: string[], tagHits: Map<string, string[]>,
    ruleIds: string[], ruleHits: Map<string, number>, matched: number) {
    this.readIds = readIds;
    this.starredIds = starredIds;
    this.hiddenIds = hiddenIds;
    this.tagIds = tagIds;
    this.tagHits = tagHits;
    this.ruleIds = ruleIds;
    this.ruleHits = ruleHits;
    this.matched = matched;
  }

  /** 是否什么都没命中（调用方据此跳过所有写操作）。 */
  isEmpty(): boolean {
    return this.readIds.length === 0 && this.starredIds.length === 0 &&
      this.hiddenIds.length === 0 && this.tagIds.length === 0;
  }
}

/**
 * 一次规则执行的结果（applyToNew 返回）。
 * 调用方用它把「规则造成的已读 / 收藏」同步给远端（RuleService 自身不依赖同步服务）。
 */
export class RuleApplyResult {
  readonly readIds: string[];
  readonly starredIds: string[];
  readonly hiddenIds: string[];
  readonly matched: number;

  constructor(readIds: string[], starredIds: string[], hiddenIds: string[], matched: number) {
    this.readIds = readIds;
    this.starredIds = starredIds;
    this.hiddenIds = hiddenIds;
    this.matched = matched;
  }

  /** 空结果（无规则 / 全部失败 / 无新文章）。 */
  static empty(): RuleApplyResult {
    return new RuleApplyResult([], [], [], 0);
  }
}
