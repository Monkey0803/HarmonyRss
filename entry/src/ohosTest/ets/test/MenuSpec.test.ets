/*
 * MenuSpec.test.ets — 下拉菜单规格模型单测（纯数据，不涉及 ArkUI 渲染）。
 *
 * 为什么要测：菜单渲染集中到 AppMenu 之后，调用点只负责拼规格；规格拼错的表现是
 * 「菜单项丢失 / 点了没反应 / 高亮错位」，靠 UI 手测很难覆盖，这里先把数据层钉住。
 */

import { describe, it, expect } from '@ohos/hypium';
import { MenuItemSpec, MenuSectionSpec, MenuSpec } from '../../../main/ets/common/components/MenuSpec';

function noop(): void {
}

export default function menuSpecTest() {
  describe('MenuSpec', () => {
    it('item_defaults', 0, () => {
      const item: MenuItemSpec = new MenuItemSpec('rename', 'Rename', noop);
      expect(item.id).assertEqual('rename');
      expect(item.label).assertEqual('Rename');
      expect(item.selected).assertFalse();
      expect(item.danger).assertFalse();
      expect(item.enabled).assertTrue();
      expect(item.icon).assertUndefined();
      expect(item.key()).assertEqual('rename');
    });

    it('fluent_modifiers', 0, () => {
      const item: MenuItemSpec = new MenuItemSpec('delete', 'Delete', noop)
        .markSelected()
        .markDanger()
        .withEnabled(false);
      expect(item.selected).assertTrue();
      expect(item.danger).assertTrue();
      expect(item.enabled).assertFalse();
    });

    it('from_items_single_section_without_header', 0, () => {
      const spec: MenuSpec = MenuSpec.fromItems([
        new MenuItemSpec('a', 'A', noop),
        new MenuItemSpec('b', 'B', noop)
      ]);
      expect(spec.sections.length).assertEqual(1);
      expect(spec.sections[0].items.length).assertEqual(2);
      expect(spec.sections[0].header).assertUndefined();
      expect(spec.width).assertUndefined();
    });

    it('from_sections_keeps_order_and_header', 0, () => {
      const sort: MenuSectionSpec = new MenuSectionSpec([
        new MenuItemSpec('newest', 'Newest', noop).markSelected()
      ], 'Sort');
      const group: MenuSectionSpec = new MenuSectionSpec([
        new MenuItemSpec('flat', 'Flat', noop).markSelected()
      ], 'Grouping');
      const spec: MenuSpec = MenuSpec.fromSections([sort, group]);
      expect(spec.sections.length).assertEqual(2);
      expect(spec.sections[0].header).assertEqual('Sort');
      expect(spec.sections[1].header).assertEqual('Grouping');
      expect(spec.sections[1].items[0].id).assertEqual('flat');
    });

    it('first_selected_id_scans_sections_in_order', 0, () => {
      const spec: MenuSpec = MenuSpec.fromSections([
        new MenuSectionSpec([new MenuItemSpec('a', 'A', noop)]),
        new MenuSectionSpec([new MenuItemSpec('b', 'B', noop).markSelected()])
      ]);
      expect(spec.firstSelectedId()).assertEqual('b');
    });

    it('first_selected_id_empty_when_nothing_selected', 0, () => {
      const spec: MenuSpec = MenuSpec.fromItems([new MenuItemSpec('a', 'A', noop)]);
      expect(spec.firstSelectedId()).assertEqual('');
    });

    it('custom_width_kept', 0, () => {
      const spec: MenuSpec = new MenuSpec([new MenuSectionSpec([new MenuItemSpec('a', 'A', noop)])], 180);
      expect(spec.width as number).assertEqual(180);
    });
  });
}
