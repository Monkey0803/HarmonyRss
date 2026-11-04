/*
 * ClearInputButton.ets — 单行输入框的清除按钮。
 *
 * 只负责「图标 + 主题色 + 无障碍」三件事；是否显示、清空后的业务副作用由使用方决定：
 * 调用方在输入内容非空时传 visible=true，并在 onClear 中回写输入内容，
 * 同时补齐原 onChange 里的联动（如清空搜索结果 / 预览 / 错误提示）。
 *
 * 为什么是 @ComponentV2：颜色来自 themePalette.accent()，visible 由父组件 @Local 驱动，
 * 全局 @Builder 不会随这些状态变化刷新；V2 的 @Param / @Event 才能保持同步。
 *
 * 密码框（InputType.Password）右侧有系统自带的「显示密码」眼睛图标，
 * 使用方通过 offsetRight + 更大的文字右内边距避让，避免两个图标重叠。
 */

import { themePalette } from '../../model/ThemePalette';

@ComponentV2
export struct ClearInputButton {
  /** 是否展示；由使用方按输入内容是否为空决定。 */
  @Param visible: boolean = false;
  /** 相对输入框右边缘的额外偏移，密码框用来避让眼睛图标，其余场景保持 0。 */
  @Param offsetRight: Length = 0;
  /** 点击清除：使用方回写空串，并复现 onChange('') 的联动逻辑。 */
  @Event onClear: () => void = () => {};

  build() {
    if (this.visible) {
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize($r('app.float.icon_size_small'))
        .fontColor([themePalette.accent()])
        .padding($r('app.float.space_xs'))
        .margin({ right: this.offsetRight })
        .accessibilityText($r('app.string.discover_clear'))
        .onClick(() => {
          this.onClear();
        })
    }
  }
}
