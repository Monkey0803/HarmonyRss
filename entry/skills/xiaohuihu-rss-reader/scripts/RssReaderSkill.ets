import { common, scriptManager, Want } from '@kit.AbilityKit';
import { articleStore } from '../../../src/main/ets/service/ArticleStore';
import { SearchHit, SearchPage, SearchQuery, SearchState } from '../../../src/main/ets/model/Search';
import { DeepLinkParams } from '../../../src/main/ets/service/DeepLink';

export default class RssReaderSkill {
  private async report(info: scriptManager.ArkTSScriptInfo, code: number,
    payload: Record<string, Object>): Promise<void> {
    const result: scriptManager.ExecuteResult = { code: code, result: payload };
    await scriptManager.completeArkTSScriptInApp(info.context, info.requestCode, result);
  }

  private failed(reason: string): Record<string, Object> {
    const payload: Record<string, Object> = {};
    payload['type'] = 'result';
    payload['status'] = 'failed';
    payload['errCode'] = reason;
    return payload;
  }

  /** arg1=关键词（可空），arg2=unread/starred/all。只返回最多五条元数据。 */
  public async findArticles(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    const keyword: string = argv.length > 0 ? argv[0].trim() : '';
    const state: string = argv.length > 1 ? argv[1].trim().toLowerCase() : SearchState.ALL;
    if (keyword.length > 100 || (state !== SearchState.ALL && state !== SearchState.UNREAD &&
      state !== SearchState.STARRED) || (keyword.length === 0 && state === SearchState.ALL)) {
      await this.report(info, -1, this.failed('ERR_INVALID_PARAMS'));
      return;
    }
    try {
      await articleStore.open(info.context);
      const query: SearchQuery = new SearchQuery(keyword);
      query.state = state;
      if (keyword.length > 0) {
        query.terms = keyword.split(' ').filter((word: string): boolean => word.length > 0);
      }
      const page: SearchPage = await articleStore.search(query, 0, 20);
      if (page.hits.length === 0) {
        await this.report(info, -1, this.failed('ERR_NOT_FOUND'));
        return;
      }
      const items: Array<Record<string, Object>> = [];
      for (let i = 0; i < page.hits.length && items.length < 5; i += 1) {
        const hit: SearchHit = page.hits[i];
        const article = await articleStore.loadById(hit.articleId);
        if (article === undefined || article.hidden) {
          continue;
        }
        const item: Record<string, Object> = {};
        item['articleId'] = hit.articleId;
        item['title'] = hit.title;
        item['source'] = hit.feedTitle;
        items.push(item);
      }
      if (items.length === 0) {
        await this.report(info, -1, this.failed('ERR_NOT_FOUND'));
        return;
      }
      const data: Record<string, Object> = {};
      data['items'] = items;
      const payload: Record<string, Object> = {};
      payload['type'] = 'result';
      payload['status'] = 'success';
      payload['data'] = data;
      await this.report(info, 0, payload);
    } catch (err) {
      await this.report(info, -1, this.failed('ERR_INTERNAL'));
    }
  }

  /** 只接受 findArticles 返回的本机文章 ID，不修改文章状态。 */
  public async openArticle(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    const articleId: string = argv.length > 0 ? argv[0].trim() : '';
    if (articleId.length === 0 || articleId.length > 512) {
      await this.report(info, -1, this.failed('ERR_INVALID_PARAMS'));
      return;
    }
    try {
      await articleStore.open(info.context);
      const article = await articleStore.loadById(articleId);
      if (article === undefined || article.hidden) {
        await this.report(info, -1, this.failed('ERR_NOT_FOUND'));
        return;
      }
      const context: common.UIAbilityContext = info.context as common.UIAbilityContext;
      const params: Record<string, Object> = {};
      params[DeepLinkParams.ARTICLE_ID] = articleId;
      params[DeepLinkParams.ACTION] = DeepLinkParams.ACTION_OPEN_READ_ONLY;
      const want: Want = {
        bundleName: context.applicationInfo.name,
        abilityName: 'EntryAbility',
        parameters: params
      };
      await context.startAbility(want);
      const data: Record<string, Object> = {};
      data['articleId'] = articleId;
      const payload: Record<string, Object> = {};
      payload['type'] = 'result';
      payload['status'] = 'success';
      payload['data'] = data;
      await this.report(info, 0, payload);
    } catch (err) {
      await this.report(info, -1, this.failed('ERR_INTERNAL'));
    }
  }
}
