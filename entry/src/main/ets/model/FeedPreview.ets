/*
 * FeedPreview.ets — 「添加订阅源」的预览/批量结果模型（纯数据，非 observable）。
 *
 * 这些对象只在一次交互内使用、随视图的 @Local 持有，不需要被框架观察，因此用普通类而非
 * @ObservedV2，避免无谓的观察开销。
 */

import { ParsedFeed } from '../service/RssParser';

/** 预览里展示的一条「最新文章」（只取标题与时间）。 */
export class PreviewItem {
  readonly title: string;
  readonly publishedAt: number;

  constructor(title: string, publishedAt: number) {
    this.title = title;
    this.publishedAt = publishedAt;
  }
}

/**
 * 一次「解析但尚未落库」的订阅源预览。
 * parsed 是抓取时已解析好的结果，确认落库时直接复用，避免二次抓取。
 */
export class FeedPreview {
  /** 用户原始输入（归一化后）。 */
  readonly inputUrl: string;
  /** 实际订阅地址；与 inputUrl 不同说明来自自动发现。 */
  readonly resolvedUrl: string;
  /** 解析到的标题（用户可在预览里改写）。 */
  readonly title: string;
  readonly siteUrl: string;
  /** 本次抓到的条目数。 */
  readonly itemCount: number;
  /** 最新 ≤ N 条，供预览展示。 */
  readonly latest: PreviewItem[];
  /** 已解析结果，commit 时复用。 */
  readonly parsed: ParsedFeed;
  readonly etag: string;
  readonly lastModified: string;
  /** 非空表示与已有订阅同站点（疑似重复），值为那个已有订阅的标题。 */
  readonly duplicateSiteTitle: string;

  constructor(inputUrl: string, resolvedUrl: string, title: string, siteUrl: string, itemCount: number,
    latest: PreviewItem[], parsed: ParsedFeed, etag: string, lastModified: string, duplicateSiteTitle: string) {
    this.inputUrl = inputUrl;
    this.resolvedUrl = resolvedUrl;
    this.title = title;
    this.siteUrl = siteUrl;
    this.itemCount = itemCount;
    this.latest = latest;
    this.parsed = parsed;
    this.etag = etag;
    this.lastModified = lastModified;
    this.duplicateSiteTitle = duplicateSiteTitle;
  }
}

/** 批量添加的结果汇总。 */
export class BatchResult {
  added: number = 0;
  duplicate: number = 0;
  failed: number = 0;
}
