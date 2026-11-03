import { UrlText } from '../common/utils/UrlText';

/** 只把明确的网页地址交给应用内 ArkWeb。 */
export function isWebLink(value: string): boolean {
  return UrlText.origin(value).length > 0;
}

/** 页内目录锚点应留在原文档，避免点目录时新开一页。 */
export function isSameDocumentAnchor(target: string, current: string): boolean {
  if (target.startsWith('#')) {
    return true;
  }
  const hash: number = target.indexOf('#');
  if (hash < 0) {
    return false;
  }
  const base: string = target.substring(0, hash);
  const currentHash: number = current.indexOf('#');
  return base === (currentHash < 0 ? current : current.substring(0, currentHash));
}

export enum ArticleLinkTarget {
  CURRENT = 'current',
  IN_APP = 'inApp',
  SYSTEM = 'system'
}

/** ArkWeb 导航与正文点击分流，避免自动跳转误开新页。 */
export function articleLinkTarget(value: string, current: string, mainFrame: boolean,
  userGesture: boolean, redirect: boolean): ArticleLinkTarget {
  if (!mainFrame || !userGesture || redirect || value.length === 0 ||
    value.startsWith('about:') || value.startsWith('data:') || value.startsWith('file:') ||
    value.startsWith('javascript:') ||
    isSameDocumentAnchor(value, current)) {
    return ArticleLinkTarget.CURRENT;
  }
  return isWebLink(value) ? ArticleLinkTarget.IN_APP : ArticleLinkTarget.SYSTEM;
}
