/* Stable facade for sync snapshot collection and application. */
import { common } from '@kit.AbilityKit';
import { SyncStore } from './SyncStore';
import { SyncSnapshotCollector } from './SyncSnapshotCollector';
import { SyncSnapshotApplier } from './SyncSnapshotApplier';

export { sameFeed, mergeSnapshot, sameArticleSnapshot } from './SyncCollectorShared';

export class SyncCollector {
  private collector: SyncSnapshotCollector;
  private applier: SyncSnapshotApplier;

  constructor(store: SyncStore, origin: string) {
    this.collector = new SyncSnapshotCollector(store, origin);
    this.applier = new SyncSnapshotApplier(store, origin);
  }

  async collect(context: common.Context, now: number): Promise<number> {
    return await this.collector.collect(context, now);
  }

  async apply(context: common.Context): Promise<number> {
    return await this.applier.apply(context);
  }
}
