/*
 * FeedAvatar.ets — 订阅源图标的首字母头像兜底（纯函数，便于单测）。
 *
 * 站点图标加载失败（无图标 / ICO 不支持 / 网络不可达）时，用标题首字 + 稳定色块代替，
 * 保证列表仍可扫读。色块从固定种子色派生，并用 ensureWhiteText 保证白字对比度。
 */

import { ThemeColorMath } from './ThemeColorMath';

/** 头像种子色：固定、与主题无关，保证同一订阅源在不同主题下颜色一致。 */
const AVATAR_SEEDS: string[] = ['#4C7BD9', '#3C8F6B', '#C05A3C', '#7C56B8', '#B0842F', '#3C86A8'];

/** 白色文字所需的最小对比度（WCAG AA 正文）。 */
const AVATAR_TEXT_CONTRAST: number = 4.5;

/** 稳定 hash：同一标题永远落在同一个种子色上。 */
function hashOf(text: string): number {
  let hash: number = 0;
  for (let i = 0; i < text.length; i += 1) {
    hash = (hash * 31 + text.charCodeAt(i)) % 1000003;
  }
  return hash;
}

/** 头像上的首字；空标题退回 ?。 */
export function feedInitial(title: string): string {
  const trimmed: string = title.trim();
  if (trimmed.length === 0) {
    return '?';
  }
  return trimmed.charAt(0).toUpperCase();
}

/** 头像底色：种子色按标题 hash 选取，并压暗到白色文字可读。 */
export function feedAvatarColor(title: string): string {
  const seed: string = AVATAR_SEEDS[hashOf(title) % AVATAR_SEEDS.length];
  return ThemeColorMath.ensureWhiteText(seed, AVATAR_TEXT_CONTRAST);
}
