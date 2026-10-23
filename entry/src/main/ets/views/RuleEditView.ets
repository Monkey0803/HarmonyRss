/*
 * RuleEditView.ets — 规则新建 / 编辑页（NavDestination 内容）。
 *
 * 表单：名称、关键词（逗号分隔，≤10）、匹配字段多选、来源范围（全部 / 指定源多选）、
 * 动作多选（已读 / 收藏 / 隐藏 / 打标签）、勾选打标签时的标签多选。
 * 校验与落库都交给 ruleViewModel；本页只把表单组装成 RuleDraft 并按 RuleError 映射文案。
 */

import { FeedSource } from '../model/Feed';
import { TagWithCount } from '../model/Tag';
import { RuleAction, RuleDraft, RuleError, RuleField } from '../model/Rule';
import { normalizeKeywords } from '../service/RuleEngine';
import { ruleViewModel } from '../viewmodel/RuleViewModel';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { tagViewModel } from '../viewmodel/TagViewModel';
import { RuleConstants } from '../common/constants/RssConstants';
import { safeArea } from '../service/SafeAreaController';

@ComponentV2
export struct RuleEditView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();

  @Local name: string = '';
  @Local keywordsText: string = '';
  @Local fields: string[] = [];
  @Local allSources: boolean = true;
  @Local feedIds: string[] = [];
  @Local actions: string[] = [];
  @Local tagIds: string[] = [];
  /** 启用开关（不能命名为 enabled：与 CustomComponent 基类的属性方法冲突）。 */
  @Local ruleEnabled: boolean = true;
  /** 最近一次校验 / 落库失败原因（RuleError 常量；空串 = 无错误）。 */
  @Local errorCode: string = '';
  @Local saving: boolean = false;

  aboutToAppear(): void {
    if (ruleViewModel.editing === undefined) {
      // 直接进入（未经过规则页的新建 / 编辑）时兜底为新建态。
      ruleViewModel.beginCreate();
    }
    const draft: RuleDraft | undefined = ruleViewModel.editing;
    if (draft !== undefined) {
      this.name = draft.name;
      this.keywordsText = draft.keywords.join(', ');
      this.fields = draft.fields.slice();
      this.allSources = draft.feedIds.length === 0;
      this.feedIds = draft.feedIds.slice();
      this.actions = draft.actions.slice();
      this.tagIds = draft.tagIds.slice();
      this.ruleEnabled = draft.enabled;
    }
    tagViewModel.load();
  }

  private isCreate(): boolean {
    return ruleViewModel.editingId.length === 0;
  }

  /** 字段 / 动作 / 标签的中英文案映射。 */
  private fieldLabel(field: string): ResourceStr {
    if (field === RuleField.TITLE) {
      return $r('app.string.rule_field_title');
    }
    if (field === RuleField.SUMMARY) {
      return $r('app.string.rule_field_summary');
    }
    if (field === RuleField.CONTENT) {
      return $r('app.string.rule_field_content');
    }
    return $r('app.string.rule_field_author');
  }

  private actionLabel(action: string): ResourceStr {
    if (action === RuleAction.READ) {
      return $r('app.string.rule_action_read');
    }
    if (action === RuleAction.STAR) {
      return $r('app.string.rule_action_star');
    }
    if (action === RuleAction.TAG) {
      return $r('app.string.rule_action_tag');
    }
    return $r('app.string.rule_action_hide');
  }

  /** 校验码 → 文案（RuleError 全量映射）。 */
  private errorMessage(): ResourceStr {
    if (this.errorCode === 'sourceEmpty' || this.errorCode === 'sourceInvalid') {
      return $r('app.string.rule_source_invalid');
    }
    if (this.errorCode === RuleError.NAME_EMPTY) {
      return $r('app.string.rule_error_name_empty');
    }
    if (this.errorCode === RuleError.NAME_TOO_LONG) {
      return $r('app.string.rule_error_name_too_long', RuleConstants.MAX_RULE_NAME);
    }
    if (this.errorCode === RuleError.KEYWORDS_EMPTY) {
      return $r('app.string.rule_error_keywords_empty');
    }
    if (this.errorCode === RuleError.KEYWORDS_TOO_MANY) {
      return $r('app.string.rule_error_keywords_too_many', RuleConstants.MAX_RULE_KEYWORDS);
    }
    if (this.errorCode === RuleError.FIELDS_EMPTY) {
      return $r('app.string.rule_error_fields_empty');
    }
    if (this.errorCode === RuleError.ACTIONS_EMPTY) {
      return $r('app.string.rule_error_actions_empty');
    }
    if (this.errorCode === RuleError.TAGS_EMPTY) {
      return $r('app.string.rule_error_tags_empty');
    }
    if (this.errorCode === RuleError.LIMIT_REACHED) {
      return $r('app.string.rule_error_limit_reached');
    }
    return $r('app.string.rule_action_failed');
  }

  private hasField(field: string): boolean {
    return this.fields.indexOf(field) >= 0;
  }

  private toggleField(field: string): void {
    this.errorCode = '';
    if (this.hasField(field)) {
      this.fields = this.fields.filter((value: string) => value !== field);
    } else {
      // 保持固定顺序（标题 / 摘要 / 正文 / 作者），便于落库与展示一致。
      const next: string[] = RuleField.all().filter((value: string) =>
        value === field || this.fields.indexOf(value) >= 0);
      this.fields = next;
    }
  }

  private hasAction(action: string): boolean {
    return this.actions.indexOf(action) >= 0;
  }

  private toggleAction(action: string): void {
    this.errorCode = '';
    if (this.hasAction(action)) {
      this.actions = this.actions.filter((value: string) => value !== action);
    } else {
      this.actions = RuleAction.all().filter((value: string) =>
        value === action || this.actions.indexOf(value) >= 0);
    }
  }

  private hasFeed(feedId: string): boolean {
    return this.feedIds.indexOf(feedId) >= 0;
  }

  private setFeed(feedId: string, selected: boolean): void {
    this.errorCode = '';
    if (selected) {
      if (!this.hasFeed(feedId)) {
        this.feedIds = this.feedIds.concat([feedId]);
      }
    } else {
      this.feedIds = this.feedIds.filter((value: string) => value !== feedId);
    }
  }

  private hasTag(tagId: string): boolean {
    return this.tagIds.indexOf(tagId) >= 0;
  }

  private setTag(tagId: string, selected: boolean): void {
    this.errorCode = '';
    if (selected) {
      if (!this.hasTag(tagId)) {
        this.tagIds = this.tagIds.concat([tagId]);
      }
    } else {
      this.tagIds = this.tagIds.filter((value: string) => value !== tagId);
    }
  }

  /** 已选来源里是否含有已被删除的源（来源失效提示）。 */
  private hasInvalidSource(): boolean {
    if (this.allSources) {
      return false;
    }
    for (let i = 0; i < this.feedIds.length; i += 1) {
      let found: boolean = false;
      for (let f = 0; f < feedViewModel.feeds.length; f += 1) {
        if (feedViewModel.feeds[f].id === this.feedIds[i]) {
          found = true;
          break;
        }
      }
      if (!found) {
        return true;
      }
    }
    return false;
  }

  /** 表单 → 草稿（只在勾选「打标签」时带上标签）。 */
  private buildDraft(): RuleDraft {
    const keywords: string[] = normalizeKeywords(this.keywordsText);
    const tagIds: string[] = this.actions.indexOf(RuleAction.TAG) >= 0 ? this.tagIds.slice() : [];
    return new RuleDraft(this.name, this.ruleEnabled, keywords, this.fields.slice(),
      this.allSources ? [] : this.feedIds.slice(), this.actions.slice(), tagIds);
  }

  /** 保存：校验失败停在本页并展示原因；成功返回上一页。 */
  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    // 关闭「全部来源」后必须至少选择一个仍有效的来源，否则等同于不限来源（与用户意图不符）。
    if (!this.allSources && this.feedIds.length === 0) {
      this.errorCode = 'sourceEmpty';
      return;
    }
    if (!this.allSources && this.hasInvalidSource()) {
      this.errorCode = 'sourceInvalid';
      return;
    }
    this.saving = true;
    const draft: RuleDraft = this.buildDraft();
    const ok: boolean = this.isCreate()
      ? await ruleViewModel.create(draft)
      : await ruleViewModel.update(ruleViewModel.editingId, draft);
    this.saving = false;
    if (!ok) {
      this.errorCode = ruleViewModel.lastError;
      return;
    }
    this.errorCode = '';
    this.navPathStack.pop();
  }

  private cancel(): void {
    ruleViewModel.cancelEdit();
    this.navPathStack.pop();
  }

  /** 可选 chip（字段 / 动作共用）。 */
  @Builder
  ChoiceChip(label: ResourceStr, selected: boolean, action: () => void) {
    Text(label)
      .fontSize($r('app.float.font_size_caption'))
      .fontColor(selected ? $r('app.color.hm_on_brand') : $r('app.color.hm_text_primary'))
      .backgroundColor(selected ? $r('app.color.hm_brand') : $r('app.color.hm_value_chip_background'))
      .borderRadius($r('app.float.radius_chip'))
      .padding({
        left: $r('app.float.space_m'),
        right: $r('app.float.space_m'),
        top: $r('app.float.space_xs'),
        bottom: $r('app.float.space_xs')
      })
      .margin({ right: $r('app.float.space_s'), bottom: $r('app.float.space_s') })
      .onClick(() => {
        action();
      })
  }

  @Builder
  FieldChips() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(RuleField.all(), (field: string) => {
        this.ChoiceChip(this.fieldLabel(field), this.hasField(field), () => {
          this.toggleField(field);
        })
      }, (field: string) => field + '_' + (this.hasField(field) ? '1' : '0'))
    }
    .width('100%')
  }

  @Builder
  ActionChips() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(RuleAction.all(), (action: string) => {
        this.ChoiceChip(this.actionLabel(action), this.hasAction(action), () => {
          this.toggleAction(action);
        })
      }, (action: string) => action + '_' + (this.hasAction(action) ? '1' : '0'))
    }
    .width('100%')
  }

  /** 订阅源多选行（仅在关闭「全部来源」时展示）。 */
  @Builder
  FeedPicker() {
    Column({ space: $r('app.float.space_xs') }) {
      if (this.hasInvalidSource()) {
        Text($r('app.string.rule_source_invalid'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .width('100%')
      }
      if (feedViewModel.feeds.length === 0) {
        Text($r('app.string.subs_empty'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      } else {
        ForEach(feedViewModel.feeds, (feed: FeedSource) => {
          Row({ space: $r('app.float.space_s') }) {
            Checkbox({ name: feed.id })
              .select(this.hasFeed(feed.id))
              .selectedColor($r('app.color.hm_brand'))
              .onChange((isOn: boolean) => {
                this.setFeed(feed.id, isOn);
              })
            Text(feed.title.length > 0 ? feed.title : feed.url)
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.hm_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: $r('app.float.space_xxs'), bottom: $r('app.float.space_xxs') })
        }, (feed: FeedSource) => feed.id + '_' + (this.hasFeed(feed.id) ? '1' : '0'))
      }
    }
    .width('100%')
  }

  /** 标签多选（仅在勾选「打标签」动作时展示）。 */
  @Builder
  TagPicker() {
    Column({ space: $r('app.float.space_xs') }) {
      if (tagViewModel.tags.length === 0) {
        Text($r('app.string.rule_tags_empty'))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      } else {
        ForEach(tagViewModel.tags, (tag: TagWithCount) => {
          Row({ space: $r('app.float.space_s') }) {
            Checkbox({ name: tag.id })
              .select(this.hasTag(tag.id))
              .selectedColor($r('app.color.hm_brand'))
              .onChange((isOn: boolean) => {
                this.setTag(tag.id, isOn);
              })
            Text(tag.name)
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.hm_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: $r('app.float.space_xxs'), bottom: $r('app.float.space_xxs') })
        }, (tag: TagWithCount) => tag.id + '_' + (this.hasTag(tag.id) ? '1' : '0'))
      }
    }
    .width('100%')
  }

  @Builder
  SectionLabel(label: ResourceStr) {
    Text(label)
      .fontSize($r('app.float.font_size_caption'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.hm_text_secondary'))
      .width('100%')
  }

  @Builder
  Form() {
    Column({ space: $r('app.float.space_l') }) {
      Column({ space: $r('app.float.space_s') }) {
        this.SectionLabel($r('app.string.rule_edit_title'))
        TextInput({ text: this.name, placeholder: $r('app.string.rule_name_hint') })
          .type(InputType.Normal)
          .maxLength(RuleConstants.MAX_RULE_NAME)
          .fontSize($r('app.float.font_size_body'))
          .width('100%')
          .onChange((value: string) => {
            this.name = value;
            this.errorCode = '';
          })
        Row({ space: $r('app.float.space_s') }) {
          Text($r('app.string.rule_enabled'))
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_text_primary'))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.ruleEnabled })
            .selectedColor($r('app.color.hm_brand'))
            .onChange((isOn: boolean) => {
              this.ruleEnabled = isOn;
            })
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: $r('app.float.space_s') }) {
        this.SectionLabel($r('app.string.rule_keywords_label'))
        TextInput({ text: this.keywordsText, placeholder: $r('app.string.rule_keywords_hint') })
          .type(InputType.Normal)
          .fontSize($r('app.float.font_size_body'))
          .width('100%')
          .onChange((value: string) => {
            this.keywordsText = value;
            this.errorCode = '';
          })
        Text($r('app.string.rule_keywords_limit_hint', RuleConstants.MAX_RULE_KEYWORDS))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: $r('app.float.space_s') }) {
        this.SectionLabel($r('app.string.rule_fields_label'))
        this.FieldChips()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: $r('app.float.space_s') }) {
        this.SectionLabel($r('app.string.rule_source_label'))
        Row({ space: $r('app.float.space_s') }) {
          Text($r('app.string.rule_source_all'))
            .fontSize($r('app.float.font_size_body'))
            .fontColor($r('app.color.hm_text_primary'))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.allSources })
            .selectedColor($r('app.color.hm_brand'))
            .onChange((isOn: boolean) => {
              this.allSources = isOn;
              this.errorCode = '';
            })
        }
        .width('100%')
        if (!this.allSources) {
          this.FeedPicker()
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: $r('app.float.space_s') }) {
        this.SectionLabel($r('app.string.rule_actions_label'))
        this.ActionChips()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      if (this.hasAction(RuleAction.TAG)) {
        Column({ space: $r('app.float.space_s') }) {
          this.SectionLabel($r('app.string.rule_tags_label'))
          this.TagPicker()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      if (this.errorCode.length > 0) {
        Text(this.errorMessage())
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_danger'))
          .width('100%')
      }

      Row({ space: $r('app.float.space_s') }) {
        Blank()
        Button($r('app.string.dialog_cancel'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .onClick(() => {
            this.cancel();
          })
        Button($r('app.string.rule_save'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_on_brand'))
          .backgroundColor($r('app.color.hm_brand'))
          .enabled(!this.saving)
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding($r('app.float.space_m'))
    .backgroundColor($r('app.color.hm_card_background'))
    .borderRadius($r('app.float.radius_card'))
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    List({ scroller: this.scroller }) {
      ListItem() {
        Column({ space: $r('app.float.space_m') }) {
          Row().width('100%').height(safeArea.contentTopInsetVp)
          this.Form()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      ListItem() {
        Row().width('100%').height(safeArea.bottomInsetVp)
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .clip(false)
    .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
