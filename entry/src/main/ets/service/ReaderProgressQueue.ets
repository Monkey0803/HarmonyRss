/* Per-mode reader positions and throttled persistence for one reading session. */
import { ReaderPosition } from './ReaderProgress';

export class ReaderProgressQueue {
  private positions: Map<string, ReaderPosition> = new Map<string, ReaderPosition>();
  private pending: ReaderPosition | undefined = undefined;
  private pendingArticleId: string = '';
  private timer: number = -1;
  private save: (articleId: string, position: ReaderPosition) => void;
  private finished: () => boolean;

  constructor(save: (articleId: string, position: ReaderPosition) => void, finished: () => boolean) {
    this.save = save;
    this.finished = finished;
  }

  private key(articleId: string, mode: string): string {
    return articleId + '|' + mode;
  }

  positionOf(articleId: string, mode: string): ReaderPosition | undefined {
    return this.positions.get(this.key(articleId, mode));
  }

  remember(articleId: string, mode: string, position: ReaderPosition): void {
    this.positions.set(this.key(articleId, mode), position);
  }

  clearArticle(articleId: string, readerMode: string, webMode: string): void {
    this.positions.delete(this.key(articleId, readerMode));
    this.positions.delete(this.key(articleId, webMode));
  }

  queue(articleId: string, mode: string, position: ReaderPosition): void {
    this.remember(articleId, mode, position);
    this.pendingArticleId = articleId;
    this.pending = position;
    if (this.timer >= 0) {
      return;
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.flush();
    }, 1200);
  }

  flush(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    const position: ReaderPosition | undefined = this.pending;
    const articleId: string = this.pendingArticleId;
    this.pending = undefined;
    this.pendingArticleId = '';
    if (position !== undefined && articleId.length > 0 && !this.finished()) {
      this.save(articleId, position);
    }
  }

  clear(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.pending = undefined;
    this.pendingArticleId = '';
  }
}
