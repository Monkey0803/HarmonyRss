/**
 * ChoiceMenu.ets — 选项表（ChoiceSet）→ 选择型菜单。
 *
 * 单独一个模块，让 MenuSpec.ets 保持零依赖（可在 ohosTest 里直接单测，
 * 而 SettingsOptions 在模块作用域就会调 $r() 取文案）。
 */

import { ChoiceOption, ChoiceSet } from '../../model/SettingsOptions';
import { MenuItemSpec, MenuSpec } from './MenuSpec';

/** 与 currentId 相等的项标为选中（未命中则无高亮）。 */
export function choiceMenu(choice: ChoiceSet, currentId: string, onPick: (id: string) => void): MenuSpec {
  const items: MenuItemSpec[] = [];
  choice.options.forEach((option: ChoiceOption) => {
    const item: MenuItemSpec = new MenuItemSpec(option.id, option.label, (): void => {
      onPick(option.id);
    });
    if (option.id === currentId) {
      item.markSelected();
    }
    items.push(item);
  });
  return MenuSpec.fromItems(items);
}
