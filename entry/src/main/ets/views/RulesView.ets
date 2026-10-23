/*
 * RulesView.ets — 本地规则列表页（NavDestination 内容，纯展示 + 事件上报）。
 *
 * 每行展示：名称、启用开关、累计命中篇数 / 最后命中时间、优先级上下移、试运行、编辑、删除。
 * 页头提供「新建规则」与「已隐藏（N）」入口。所有状态来自 ruleViewModel（@ObservedV2），
 * 本页只在切换页面时主动 load 一次。
 */

import { Rule, RuleTestResult } from '../model/Rule';
import { ruleViewModel } from '../viewmodel/RuleViewModel';
import { feedViewModel } from '../viewmodel/FeedViewModel';
import { tagViewModel } from '../viewmodel/TagViewModel';
import { RouterConstants } from '../common/constants/RouterConstants';
import { RuleConstants } from '../common/constants/RssConstants';
import { MaterialController } from '../service/MaterialController';
import { appSettings } from '../model/AppSettings';
import { safeArea } from '../service/SafeAreaController';
import { DateUtil } from '../common/utils/DateUtil';
import { ToastUtil } from '../common/utils/ToastUtil';

@ComponentV2
export struct RulesView {
  @Param navPathStack: NavPathStack = new NavPathStack();
  @Param scroller: Scroller = new Scroller();
  /** 最近一次试运行对应的规则 id（试运行结果按行展示）。 */
  @Local testedRuleId: string = '';

  aboutToAppear(): void {
    ruleViewModel.load();
    ruleViewModel.refreshHiddenCount();
    tagViewModel.load();
  }

  /** 新建：进入编辑态后压入编辑页。 */
  private startCreate(): void {
    ruleViewModel.beginCreate();
    this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_RULE_EDIT, ''));
  }

  /** 编辑：预填当前值后压入编辑页。 */
  private startEdit(rule: Rule): void {
    ruleViewModel.beginEdit(rule);
    this.testedRuleId = '';
    this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_RULE_EDIT, ''));
  }

  /** 打开已隐藏文章列表。 */
  private openHidden(): void {
    this.navPathStack.pushPath(new NavPathInfo(RouterConstants.PAGE_HIDDEN, ''));
  }

  /** 试运行：只统计不写入（结果放在 ruleViewModel.testResult）。 */
  private runTest(rule: Rule): void {
    this.testedRuleId = rule.id;
    ruleViewModel.testRun(rule.id, RuleConstants.RULE_TEST_SAMPLE).catch((err: Error) => {
      ToastUtil.show(this.getUIContext(), $r('app.string.rule_action_failed'));
    });
  }

  /** 启停：先改内存让开关立即响应，再落库刷新。 */
  private toggleEnabled(rule: Rule, enabled: boolean): void {
    rule.enabled = enabled;
    ruleViewModel.setEnabled(rule.id, enabled).catch((err: Error) => {
      ToastUtil.show(this.getUIContext(), $r('app.string.rule_action_failed'));
    });
  }

  private moveRule(rule: Rule, delta: number): void {
    ruleViewModel.move(rule.id, delta).catch((err: Error) => {
      ToastUtil.show(this.getUIContext(), $r('app.string.rule_action_failed'));
    });
  }

  /** 删除前确认：已产生的文章状态不会回滚。 */
  private confirmRemove(rule: Rule): void {
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.dialog_cancel'),
      action: () => {
      }
    };
    const removeButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.rule_remove'),
      fontColor: $r('app.color.hm_danger'),
      action: () => {
        ruleViewModel.remove(rule.id).catch((err: Error) => {
          ToastUtil.show(this.getUIContext(), $r('app.string.rule_action_failed'));
        });
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.rule_remove_confirm_title'),
      message: $r('app.string.rule_remove_confirm_message'),
      autoCancel: true,
      primaryButton: cancelButton,
      secondaryButton: removeButton
    };
    this.getUIContext().showAlertDialog(MaterialController.dialogParams(params, appSettings.immersiveOn));
  }

  /** 最近一次命中时间文案。 */
  private lastHitText(rule: Rule): ResourceStr {
    return rule.lastHitAt > 0
      ? $r('app.string.rule_last_hit', DateUtil.format(rule.lastHitAt))
      : $r('app.string.rule_never_hit');
  }

  /** 是否展示试运行结果。 */
  private showsTestResult(ruleId: string): boolean {
    return this.testedRuleId === ruleId && ruleViewModel.testResult !== undefined &&
      ruleViewModel.testingId.length === 0;
  }

  /** 试运行结果文案（最近 N 篇中命中 M 篇）。 */
  private testResultText(ruleId: string): ResourceStr {
    if (!this.showsTestResult(ruleId)) {
      return '';
    }
    const result: RuleTestResult | undefined = ruleViewModel.testResult;
    if (result === undefined) {
      return '';
    }
    return $r('app.string.rule_test_result', result.scanned, result.matched);
  }

  @Builder
  Header() {
    Column({ space: $r('app.float.space_m') }) {
      Row().width('100%').height(safeArea.contentTopInsetVp)

      Row({ space: $r('app.float.space_s') }) {
        Column({ space: $r('app.float.space_xs') }) {
          Text($r('app.string.rule_title'))
            .fontSize($r('app.float.font_size_section'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.hm_text_primary'))
          Text($r('app.string.rule_entry', ruleViewModel.rules.length))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button($r('app.string.rule_new'))
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .enabled(ruleViewModel.rules.length < RuleConstants.MAX_RULES)
          .onClick(() => {
            this.startCreate();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.rule_manage_hint'))
        .fontSize($r('app.float.font_size_caption'))
        .fontColor($r('app.color.hm_text_secondary'))
        .width('100%')

      // 已隐藏入口：与规则列表并列；计数直接读 FeedViewModel 内存态，取消隐藏后自动刷新。
      Row({ space: $r('app.float.space_m') }) {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([$r('app.color.hm_brand')])
        Text($r('app.string.rule_hidden_entry', feedViewModel.hiddenCount()))
          .fontSize($r('app.float.font_size_body'))
          .fontColor($r('app.color.hm_text_primary'))
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize($r('app.float.icon_size_small'))
          .fontColor([$r('app.color.hm_text_secondary')])
      }
      .width('100%')
      .padding($r('app.float.space_m'))
      .backgroundColor($r('app.color.hm_card_background'))
      .borderRadius($r('app.float.radius_card'))
      .onClick(() => {
        this.openHidden();
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 一行操作按钮（文字按钮，避免引入额外符号 / V1 组件）。 */
  @Builder
  ActionButton(label: ResourceStr, danger: boolean, action: () => void) {
    Button(label)
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .fontSize($r('app.float.font_size_caption'))
      .fontColor(danger ? $r('app.color.hm_danger') : $r('app.color.hm_text_secondary'))
      .padding({ left: $r('app.float.space_xs'), right: $r('app.float.space_xs') })
      .onClick(() => {
        action();
      })
  }

  @Builder
  RuleRow(rule: Rule) {
    Column({ space: $r('app.float.space_xs') }) {
      Row({ space: $r('app.float.space_m') }) {
        Column({ space: $r('app.float.space_xxs') }) {
          Text(rule.name)
            .fontSize($r('app.float.font_size_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.hm_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(rule.keywords.join(' + '))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: rule.enabled })
          .selectedColor($r('app.color.hm_brand'))
          .onChange((isOn: boolean) => {
            this.toggleEnabled(rule, isOn);
          })
      }
      .width('100%')

      Row({ space: $r('app.float.space_m') }) {
        Text($r('app.string.rule_match_count', rule.matchCount))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
        Text(this.lastHitText(rule))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_text_secondary'))
          .layoutWeight(1)
      }
      .width('100%')

      if (this.showsTestResult(rule.id)) {
        Text(this.testResultText(rule.id))
          .fontSize($r('app.float.font_size_caption'))
          .fontColor($r('app.color.hm_brand'))
          .width('100%')
      }

      Row() {
        this.ActionButton($r('app.string.rule_move_up'), false, () => {
          this.moveRule(rule, -1);
        })
        this.ActionButton($r('app.string.rule_move_down'), false, () => {
          this.moveRule(rule, 1);
        })
        this.ActionButton(ruleViewModel.testingId === rule.id
          ? $r('app.string.rule_testing')
          : $r('app.string.rule_test'), false, () => {
          this.runTest(rule);
        })
        Blank()
        this.ActionButton($r('app.string.rule_edit'), false, () => {
          this.startEdit(rule);
        })
        this.ActionButton($r('app.string.rule_remove'), true, () => {
          this.confirmRemove(rule);
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
        this.Header()
      }
      .margin({ bottom: $r('app.float.space_s') })

      if (ruleViewModel.loading && ruleViewModel.rules.length === 0) {
        ListItem() {
          Text($r('app.string.home_loading'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding($r('app.float.space_2xl'))
        }
      } else if (ruleViewModel.rules.length === 0) {
        ListItem() {
          Text($r('app.string.rule_empty'))
            .fontSize($r('app.float.font_size_caption'))
            .fontColor($r('app.color.hm_text_secondary'))
            .padding($r('app.float.space_2xl'))
        }
      } else {
        ForEach(ruleViewModel.rules, (rule: Rule) => {
          ListItem() {
            this.RuleRow(rule)
          }
          .margin({ bottom: $r('app.float.space_s') })
        }, (rule: Rule) => rule.id + '_' + rule.enabled + '_' + rule.matchCount + '_' + rule.lastHitAt +
          '_' + (this.testedRuleId === rule.id ? 't' : 'n') +
          '_' + (ruleViewModel.testingId === rule.id ? '1' : '0'))
      }

      ListItem() {
        Row().width('100%').height(safeArea.bottomInsetVp)
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .clip(false)
    .cachedCount(3, true)
    .padding({ left: $r('app.float.space_l'), right: $r('app.float.space_l') })
    .backgroundColor($r('app.color.hm_page_transparent'))
  }
}
