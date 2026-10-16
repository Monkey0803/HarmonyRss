/*
 * ImageTabView.ets — 图片领域页签的占位实现（基模板）。
 *
 * `--domain image` 时被 application-image/ 里的真实实现覆盖。基模板下 IMAGE_DOMAIN 为 false，
 * 该页签根本不会挂载。
 *
 * 无状态、单处使用，按 @performance/avoid-overusing-custom-component-check 的建议
 * 用全局 @Builder 实现。调用处写法不变：`ImageTabView()`。
 */

@Builder
export function ImageTabView() {
  Column()
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.hm_page_transparent'))
}
