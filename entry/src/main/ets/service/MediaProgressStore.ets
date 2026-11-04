/* 音频播放进度读写，复用文章仓储的现有连接。 */
import { Article } from '../model/Feed';
import { articleRepository } from './ArticleServices';

export class MediaProgressStore {
  async load(articleId: string): Promise<number> {
    const article: Article | undefined = await articleRepository.loadById(articleId);
    return article !== undefined ? article.mediaProgress : 0;
  }

  async save(articleId: string, seconds: number): Promise<void> {
    await articleRepository.setMediaProgress(articleId, seconds);
  }
}
