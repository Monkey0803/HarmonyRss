/*
 * ReaderImageViewer.ets — 正文图片全屏查看器（纯 V2）。
 *
 * 交互：单指拖动平移（放大后）、双指捏合缩放、单击在 1x / 2.5x 之间切换；
 * 右上角是系统保存控件（SaveButton）：点它才会拿到一次性媒体库授权，
 * 之后由父组件把图片写进相册。关闭按钮在左上角。
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { safeArea } from '../service/SafeAreaController';
import { readerImageSave } from '../service/ReaderImageSave';

@ComponentV2
export struct ReaderImageViewer {
  @Param src: string = '';
  /** 文章地址：远程图下载时带 Referer（很多 CDN 会拒绝无来源的请求）。 */
  @Param referer: string = '';
  @Event onClose: () => void = () => {};
  @Event onSave: (src: string) => void = () => {};

  /** 实际交给 Image 的地址：远程图先取回字节再转 data URI。 */
  @Local displaySrc: string = '';
  @Local loaded: boolean = false;
  @Local failed: boolean = false;
  @Local zoom: number = 1;
  @Local panX: number = 0;
  @Local panY: number = 0;
  private baseZoom: number = 1;
  private dragStartX: number = 0;
  private dragStartY: number = 0;

  /**
   * 远程图不走 Image 的直连（会被防盗链拦住）：先用带 Referer 的下载转 data URI。
   * data URI（离线内联图）直接显示。
   */
  aboutToAppear(): void {
    if (this.src.startsWith('data:')) {
      this.displaySrc = this.src;
      return;
    }
    readerImageSave.toDataUri(this.src, this.referer).then((uri: string) => {
      if (uri.length > 0) {
        this.displaySrc = uri;
      } else {
        this.loaded = true;
        this.failed = true;
      }
    }).catch(() => {
      this.loaded = true;
      this.failed = true;
    });
  }

  /** 1x ↔ 2.5x。 */
  private toggleZoom(): void {
    this.zoom = this.zoom > 1 ? 1 : 2.5;
    if (this.zoom === 1) {
      this.panX = 0;
      this.panY = 0;
    }
  }

  private resetPan(): void {
    this.panX = 0;
    this.panY = 0;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 加载中 / 加载失败都要有反馈：整屏全黑会让人以为卡死。
      if (this.failed) {
        Text($r('app.string.image_load_failed'))
          .fontSize($r('app.float.font_size_body'))
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .padding($r('app.float.space_l'))
      } else if (this.displaySrc.length === 0 || !this.loaded) {
        LoadingProgress()
          .width($r('app.float.web_loading_size'))
          .height($r('app.float.web_loading_size'))
          .color(Color.White)
      }

      if (this.displaySrc.length > 0 && !this.failed) {
        Image(this.displaySrc)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .interpolation(ImageInterpolation.High)
          .scale({ x: this.zoom, y: this.zoom })
          .translate({ x: this.panX, y: this.panY })
          .onComplete(() => {
            this.loaded = true;
          })
          .onError(() => {
            this.loaded = true;
            this.failed = true;
          })
          .onClick(() => {
            this.toggleZoom();
          })
          .gesture(
            GestureGroup(GestureMode.Parallel,
              PinchGesture({ fingers: 2 })
                .onActionStart(() => {
                  this.baseZoom = this.zoom;
                })
                .onActionUpdate((event: GestureEvent) => {
                  const next: number = this.baseZoom * event.scale;
                  this.zoom = Math.min(4, Math.max(1, next));
                  if (this.zoom === 1) {
                    this.resetPan();
                  }
                }),
              PanGesture()
                .onActionStart(() => {
                  this.dragStartX = this.panX;
                  this.dragStartY = this.panY;
                })
                .onActionUpdate((event: GestureEvent) => {
                  if (this.zoom <= 1) {
                    return;
                  }
                  this.panX = this.dragStartX + event.offsetX;
                  this.panY = this.dragStartY + event.offsetY;
                })
            )
          )
      }

      // 顶部操作条：关闭 + 保存控件（保存控件负责申请一次性相册授权）。
      Row({ space: $r('app.float.space_s') }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize($r('app.float.icon_size'))
          .fontColor([Color.White])
          .padding($r('app.float.space_m'))
          .backgroundColor('#66000000')
          .borderRadius($r('app.float.icon_size'))
          .accessibilityText($r('app.string.action_back'))
          .onClick(() => {
            this.onClose();
          })

        Blank()

        SaveButton({
          icon: SaveIconStyle.FULL_FILLED,
          text: SaveDescription.SAVE_IMAGE,
          buttonType: ButtonType.Capsule
        })
          .onClick((event: ClickEvent, result: SaveButtonOnClickResult, error?: BusinessError) => {
            if (result === SaveButtonOnClickResult.SUCCESS) {
              this.onSave(this.src);
              return;
            }
            if (error !== undefined) {
              console.warn('save button authorization failed: ' + error.code.toString());
            }
          })
      }
      .width('100%')
      .padding({
        left: $r('app.float.space_l'),
        right: $r('app.float.space_l'),
        top: safeArea.contentTopInsetVp + 8
      })
      .alignItems(VerticalAlign.Center)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }
}
