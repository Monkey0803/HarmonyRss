import { LiveFormExtensionAbility, LiveFormInfo } from '@kit.FormKit';
import { UIExtensionContentSession } from '@kit.AbilityKit';

/** 激活页只绘制短动效，不需要跨页传状态或 V1 LocalStorage。 */
export default class RssLiveFormAbility extends LiveFormExtensionAbility {
  onLiveFormCreate(liveFormInfo: LiveFormInfo, session: UIExtensionContentSession): void {
    session.loadContent('form/RssLiveCardPage');
  }
}
