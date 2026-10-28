/*
 * BrandTitle.ets — 阅读页签标题栏的品牌标识（App logo + HarmonyRss 文字）。
 *
 * 替代原来的纯文字标题「阅读」：挂在 HdsNavigation 标题栏的 stackBuilder 上，
 * 与筛选条（bottomBuilder）同处标题栏生效区域。
 *
 * 用全局 @Builder 而不是自定义组件：这里只有静态布局，没必要多一层组件实例
 * （CodeLinter @performance/avoid-overusing-custom-component-check）。
 */

import { AppLogo } from '../common/components/AppLogo';
import { appSettings } from '../model/AppSettings';
import { CommonConstants } from '../common/constants/CommonConstants';

@Builder
export function BrandTitle() {
  Row({ space: $r('app.float.space_s') }) {
    AppLogo({
      logoKind: appSettings.logoKind,
      logoSize: CommonConstants.LOGO_BRAND_SIZE,
      cornerRadius: CommonConstants.LOGO_BRAND_RADIUS
    })
    Text($r('app.string.brand_name'))
      .fontSize($r('app.float.font_size_title'))
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.hm_text_primary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .layoutWeight(1)
  }
  .width('100%')
  .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
  .alignItems(VerticalAlign.Center)
}
