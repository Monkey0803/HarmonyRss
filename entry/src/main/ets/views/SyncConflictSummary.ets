import { SyncConflict, SyncKinds } from '../model/Sync';

/** 上次同步冲突摘要，接收快照而不持有同步状态。 */
@ComponentV2
export struct SyncConflictSummary {
  @Param conflicts: number = 0;
  @Param items: SyncConflict[] = [];

  /** 冲突实体的中文名；未知类型归到「其他」。 */
  private kindLabel(kind: string): ResourceStr {
    switch (kind) {
      case SyncKinds.ARTICLE_STATE:
        return $r('app.string.sync_kind_article_state');
      case SyncKinds.FEED:
        return $r('app.string.tab_subs');
      case SyncKinds.HIGHLIGHT:
        return $r('app.string.hl_panel_entry');
      case SyncKinds.TAG:
        return $r('app.string.tag_title');
      case SyncKinds.ARTICLE_TAG:
        return $r('app.string.sync_kind_article_tag');
      case SyncKinds.SETTINGS:
        return $r('app.string.tab_settings');
      case SyncKinds.SMART_FOLDER:
        return $r('app.string.smart_folder_title');
      case SyncKinds.RULE:
        return $r('app.string.rule_title');
      case SyncKinds.TEMPLATE:
        return $r('app.string.tpl_section_title');
      default:
        return $r('app.string.sync_kind_other');
    }
  }

  /** 冲突字段的中文名；未知字段直接显示原名（不猜语义）。 */
  private fieldLabel(field: string): ResourceStr {
    if (field === 'read') {
      return $r('app.string.a11y_article_read');
    }
    if (field === 'starred') {
      return $r('app.string.filter_starred');
    }
    if (field === 'saved') {
      return $r('app.string.filter_saved');
    }
    if (field === 'progress' || field === 'progressRatio') {
      return $r('app.string.sync_field_progress');
    }
    return field;
  }

  /** 记录键去掉类型前缀后截断，详情行不撑破卡片。 */
  private shortKey(key: string): string {
    const at: number = key.indexOf(':');
    const value: string = at >= 0 ? key.substring(at + 1) : key;
    return value.length > 28 ? value.substring(0, 28) + '…' : value;
  }

  build() {
    Column() {
        // 只有真的发生过「两端都改」才提示，0 条时不打扰。
        if (this.conflicts > 0) {
          Text($r('app.string.sync_conflicts_merged', this.conflicts))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .width('100%')
            .margin({ top: $r('app.float.space_s'), left: $r('app.float.space_xs') })

          if (this.items.length > 0) {
            Column({ space: $r('app.float.space_xs') }) {
              ForEach(this.items.slice(0, 5), (item: SyncConflict) => {
                Row({ space: $r('app.float.space_xs') }) {
                  Text(this.kindLabel(item.kind))
                    .fontSize($r('app.float.font_size_caption'))
                    .fontColor($r('app.color.hm_text_secondary'))
                  Text(this.shortKey(item.key))
                    .fontSize($r('app.float.font_size_caption'))
                    .fontColor($r('app.color.hm_text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  if (item.fields.length === 0) {
                    Text($r('app.string.sync_conflict_no_fields'))
                      .fontSize($r('app.float.font_size_caption'))
                      .fontColor($r('app.color.hm_text_secondary'))
                  } else {
                    ForEach(item.fields, (field: string) => {
                      Text(this.fieldLabel(field))
                        .fontSize($r('app.float.font_size_caption'))
                        .fontColor($r('app.color.hm_text_secondary'))
                    }, (field: string) => field)
                  }
                }
                .width('100%')
              }, (item: SyncConflict) => item.key)
            }
            .width('100%')
            .margin({ top: $r('app.float.space_xs'), left: $r('app.float.space_xs') })
          }
        }

    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
