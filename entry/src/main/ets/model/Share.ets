/*
 * Share.ets — 分享目标扩展的领域模型。
 *
 * 面板与目标只依赖统一的 ShareContext，避免详情页 / 列表 / 高亮页各传一套参数；
 * ShareTarget 只描述「怎么投递」，真正的 URL 构造在 ShareTargets（纯函数，可单测）。
 * 所有类都显式声明字段与构造函数，遵循 ArkTS 严格模式（无对象字面量当类型）。
 */

/** 分享上下文的种类（决定面板可用的动作）。 */
export class ShareKind {
  /** 整篇文章：标题 / 链接 / 摘要 / 标签 / 正文。 */
  static readonly ARTICLE: string = 'article';
  /** 单条高亮：引文 + 备注 + 所属文章链接。 */
  static readonly HIGHLIGHT: string = 'highlight';
  /** 纯文本（无来源）。 */
  static readonly TEXT: string = 'text';
}

/** 目标类型：决定执行方式与失败降级策略。 */
export class ShareTargetType {
  /** 系统分享面板（ShareKit）。 */
  static readonly SYSTEM: string = 'system';
  /** 第三方 App 的 URL Scheme。 */
  static readonly SCHEME: string = 'scheme';
  /** mailto 邮件。 */
  static readonly MAILTO: string = 'mailto';
  /** 写入剪贴板。 */
  static readonly CLIPBOARD: string = 'clipboard';
  /** 应用内动作（如稍后读），由调用方处理。 */
  static readonly INTERNAL: string = 'internal';
}

/**
 * 统一分享上下文。字段一律非空字符串（空串表示没有该项），
 * 这样面板不必到处判 undefined。
 */
export class ShareContext {
  /** ShareKind 之一。 */
  readonly kind: string;
  readonly title: string;
  readonly url: string;
  readonly summary: string;
  readonly author: string;
  /** 本地标签名（已归一，不含 # 前缀）。 */
  readonly tags: string[];
  /** 正文纯文本（文章 / 高亮正文）。 */
  readonly body: string;
  /** 高亮引文；文章上下文为空串。 */
  readonly quote: string;
  /** 高亮备注；文章上下文为空串。 */
  readonly note: string;
  /** 所属文章 id；纯文本为空串。 */
  readonly articleId: string;
  /** 所属订阅源标题（导出 Markdown 时作「来源」行）；无来源为空串。 */
  readonly feedTitle: string;

  constructor(kind: string, title: string = '', url: string = '', summary: string = '',
    author: string = '', tags: string[] = [], body: string = '', quote: string = '',
    note: string = '', articleId: string = '', feedTitle: string = '') {
    this.kind = kind;
    this.title = title;
    this.url = url;
    this.summary = summary;
    this.author = author;
    this.tags = tags;
    this.body = body;
    this.quote = quote;
    this.note = note;
    this.articleId = articleId;
    this.feedTitle = feedTitle;
  }

  /** 空上下文（面板未打开时的占位，避免可选字段）。 */
  static empty(): ShareContext {
    return new ShareContext(ShareKind.TEXT);
  }
}

/** 一个分享目标：id 稳定，labelKey 指向资源文案。 */
export class ShareTarget {
  readonly id: string;
  /** 文案资源 key（如 share_action_system）。 */
  readonly labelKey: string;
  /** ShareTargetType 之一。 */
  readonly type: string;
  /** 是否必须有文章链接（缺链接时置灰）。 */
  readonly requiresUrl: boolean;

  constructor(id: string, labelKey: string, type: string, requiresUrl: boolean = false) {
    this.id = id;
    this.labelKey = labelKey;
    this.type = type;
    this.requiresUrl = requiresUrl;
  }
}

/** 自定义分享模板（持久化到偏好库）。 */
@ObservedV2
export class ShareTemplate {
  readonly id: string;
  @Trace name: string;
  /** 模板正文，占位符形如 {title}。 */
  @Trace content: string;
  /** 展示顺序（升序）。 */
  @Trace sort: number;

  constructor(id: string, name: string, content: string, sort: number = 0) {
    this.id = id;
    this.name = name;
    this.content = content;
    this.sort = sort;
  }
}

/**
 * 一次分享动作的结果。
 * messageKey 是资源 key（空串表示不需要提示），由宿主统一用 Toast 展示。
 */
export class ShareResult {
  readonly ok: boolean;
  readonly targetId: string;
  /** 目标拉起失败后是否已自动复制链接兜底。 */
  readonly fallbackCopied: boolean;
  readonly messageKey: string;

  constructor(ok: boolean, targetId: string = '', fallbackCopied: boolean = false,
    messageKey: string = '') {
    this.ok = ok;
    this.targetId = targetId;
    this.fallbackCopied = fallbackCopied;
    this.messageKey = messageKey;
  }
}
