import { describe, it, expect } from '@ohos/hypium';
import { ArticleDataSource } from '../../../main/ets/viewmodel/ArticleDataSource';

class TestItem {
  readonly id: number;
  constructor(id: number) { this.id = id; }
}

class ChangeRecorder implements DataChangeListener {
  reloads: number = 0;
  added: number[] = [];
  changed: number[] = [];

  onDataReloaded(): void { this.reloads += 1; }
  onDataAdded(index: number): void {}
  onDataAdd(index: number): void { this.added.push(index); }
  onDataChanged(index: number): void {}
  onDataChange(index: number): void { this.changed.push(index); }
  onDataDeleted(index: number): void {}
  onDataDelete(index: number): void {}
  onDataMoved(from: number, to: number): void {}
  onDataMove(from: number, to: number): void {}
  onDatasetChange(dataOperations: DataOperation[]): void {}
}

export default function articleDataSourceTest() {
  describe('ArticleDataSource', () => {
    it('appends_visible_page_without_reloading_existing_rows', 0, () => {
      const source: ArticleDataSource = new ArticleDataSource();
      const listener: ChangeRecorder = new ChangeRecorder();
      source.registerDataChangeListener(listener);
      const first: TestItem = new TestItem(1);
      const second: TestItem = new TestItem(2);
      source.setItems([first]);
      source.setItems([first, second], true);
      expect(source.totalCount()).assertEqual(2);
      expect(source.getData(1)).assertEqual(second);
      expect(listener.reloads).assertEqual(1);
      expect(listener.added.join(',')).assertEqual('1');
    });

    it('full_update_reloads_existing_rows', 0, () => {
      const source: ArticleDataSource = new ArticleDataSource();
      const listener: ChangeRecorder = new ChangeRecorder();
      source.registerDataChangeListener(listener);
      const item: TestItem = new TestItem(1);
      source.setItems([item]);
      source.setItems([item]);
      expect(listener.reloads).assertEqual(2);
      expect(listener.added.length).assertEqual(0);
    });

    it('single_row_change_keeps_other_rows', 0, () => {
      const source: ArticleDataSource = new ArticleDataSource();
      const listener: ChangeRecorder = new ChangeRecorder();
      source.registerDataChangeListener(listener);
      const first: TestItem = new TestItem(1);
      const second: TestItem = new TestItem(2);
      source.setItems([first, second]);
      source.setItems([first, second], false, 1);
      expect(listener.reloads).assertEqual(1);
      expect(listener.changed.join(',')).assertEqual('1');
    });
  });
}
