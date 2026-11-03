/*
 * AppSheet.ets — 全 App 统一的半模态宿主（纯状态管理 V2）。
 *
 * 两件事固定在这里，调用方只写「面板内容」：
 *   1. 系统材质：复用 MaterialController.overlayMaterial（官方「半模态设置系统材质」示例），
 *      并把背板色让位为透明；API < 26 / 设备不支持时自动退回普通背板；
 *   2. 三挡高度：detents 由 sheetDetentsFor 生成（官方「设置三个不同高度的挡位」示例），
 *      面板可上下拖动吸附到初始挡 / 展开挡 / 紧凑挡。
 *
 * 用法（必须在 Stack 内与页面内容同级，不要把宿主放进 List / Refresh / Scroll）：
 *   Stack() {
 *     // ...页面内容...
 *     AppSheet({ visible: this.showSheet, initialSize: SheetSize.LARGE, onDismiss: () => { ... } }) {
 *       this.SheetContent()
 *     }
 *   }
 *
 * 注意：bindSheet 在拖拽关闭时不会回写 isShow，所以宿主用 onDisappear 触发 onDismiss，
 * 由父组件复位 show / mode 等状态。
 */

import { appSettings } from '../../model/AppSettings';
import { MaterialController } from '../../service/MaterialController';
import { AppSheetDetents, sheetDetentsFor } from './SheetDetents';

@ComponentV2
export struct AppSheet {
  /** 半模态显隐：父组件的 @Local 直接传进来。 */
  @Param visible: boolean = false;
  /** 首挡高度：SheetSize 或固定 vp（保持各面板迁移前的初始高度）。 */
  @Param initialSize: SheetSize | Length = SheetSize.MEDIUM;
  /** 是否显示系统关闭按钮（自绘关闭按钮的面板传 false）。 */
  @Param showClose: boolean = true;
  /** 是否显示控制条。 */
  @Param dragBar: boolean = true;
  /** 下滑 / 点遮罩 / 关闭按钮关闭后回调：父组件在这里复位 show 与 mode。 */
  @Event onDismiss: () => void = () => {
  };

  /** @BuilderParam 的默认值必须是 @Builder 方法（不能是箭头函数）。 */
  @Builder
  emptyContent() {
  }

  @BuilderParam content: () => void = this.emptyContent;

  /** 首挡不变时复用同一个三元组，避免页面刷新时反复下发新的 detents。 */
  @Computed
  get sheetDetents(): AppSheetDetents {
    return sheetDetentsFor(this.initialSize);
  }

  /** bindSheet 的 builder 参数必须来自 @Builder 方法，不能直接传 @BuilderParam 的调用结果。 */
  @Builder
  sheetContent() {
    this.content()
  }

  private options(): SheetOptions {
    const options: SheetOptions = {
      detents: this.sheetDetents,
      dragBar: this.dragBar,
      showClose: this.showClose,
      onDisappear: () => {
        this.onDismiss();
      }
    };
    // 系统材质：内部会在可用时设置 systemMaterial 并把背板色改成 Transparent。
    return MaterialController.sheetOptions(options, appSettings.immersiveOn);
  }

  build() {
    // 满尺寸透明宿主、不参与命中测试：
    //   - bindSheet 必须挂在已上树节点上；
    //   - 宽屏 preferType=POPUP 时弹层相对宿主定位，满尺寸与原先「挂在页面根节点」一致，位置不漂移；
    //   - HitTestMode.None 让页面触摸直接透传，不影响下层内容。
    Stack()
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
      .bindSheet(this.visible, this.sheetContent(), this.options())
  }
}
