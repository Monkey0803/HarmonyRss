/** 保存独立网页前的预览；正文片段只保存在内存中，用户确认后才写库。 */
export const WEB_PAGE_FEED_ID: string = 'local:saved-web';

export class WebPagePreview {
  readonly url: string;
  readonly title: string;
  readonly source: string;
  readonly summary: string;
  readonly plainText: string;
  readonly readerHtml: string;

  constructor(url: string, title: string, source: string, summary: string,
    plainText: string, readerHtml: string) {
    this.url = url;
    this.title = title;
    this.source = source;
    this.summary = summary;
    this.plainText = plainText;
    this.readerHtml = readerHtml;
  }
}
