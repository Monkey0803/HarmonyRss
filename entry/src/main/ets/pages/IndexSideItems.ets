import { HdsSideMenuMainItem } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { TabIndex } from '../common/constants/NavigationConstants';
import { IMAGE_DOMAIN } from '../common/constants/DomainConstants';

/** Shared item definitions for the wide-screen navigation rail. */
export function buildIndexSideItems(selectTab: (index: number) => void): HdsSideMenuMainItem[] {
    const items: HdsSideMenuMainItem[] = [];
    items.push(new HdsSideMenuMainItem({
      itemId: 'home',
      label: $r('app.string.tab_home'),
      symbol: new SymbolGlyphModifier($r('sys.symbol.house')),
      action: () => {
        selectTab(TabIndex.HOME);
      }
    }));
    items.push(new HdsSideMenuMainItem({
      itemId: 'subs',
      label: $r('app.string.tab_subs'),
      symbol: new SymbolGlyphModifier($r('sys.symbol.folder')),
      action: () => {
        selectTab(TabIndex.SUBSCRIPTIONS);
      }
    }));
    items.push(new HdsSideMenuMainItem({
      itemId: 'settings',
      label: $r('app.string.tab_settings'),
      symbol: new SymbolGlyphModifier($r('sys.symbol.gearshape')),
      action: () => {
        selectTab(TabIndex.SETTINGS);
      }
    }));
    if (IMAGE_DOMAIN) {
      items.push(new HdsSideMenuMainItem({
        itemId: 'images',
        label: $r('app.string.tab_images'),
        symbol: new SymbolGlyphModifier($r('sys.symbol.picture')),
        action: () => {
          selectTab(TabIndex.IMAGES);
        }
      }));
    }
    return items;
}
