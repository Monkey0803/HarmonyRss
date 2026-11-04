# toast-kit

HarmonyOS 可复用 Toast 库。底层使用系统 `promptAction.showToast`，不引入自绘浮层；调用方初始化一次后即可在任意位置 `Toast.show(...)`，无需再传 `this.getUIContext()`。

- **OHPM**：`@monkey0803/toast-kit@1.0.0`
- **Gitee**：https://gitee.com/monkey0803/toast-kit

## 安装

```bash
ohpm install @monkey0803/toast-kit
```

> 发布包构建基线：HarmonyOS 6.1.0（API 23）。

## 特性

- 零上下文调用：`Toast.show($r('app.string.saved'))`
- 自动容错：无 UI 上下文 / `showToast` 抛异常时只记日志，不影响业务
- 多 Ability / UIExtension 支持：`init(windowStage)` + `attach(uiContext)`
- 可插拔 options 装饰器：宿主可注入 HDS 沉浸光感材质等定制
- 无业务依赖：库只依赖 `@kit.ArkUI` / `@kit.BasicServicesKit` / `@kit.PerformanceAnalysisKit`

## 接入

### 1. 添加依赖

**Gitee 源码方式**（独立仓库 clone 后）：

```json5
// entry/oh-package.json5
{
  "dependencies": {
    "@monkey0803/toast-kit": "file:../toast-kit/library"
  }
}
```

> 若直接在 HarmonyRss 主工程内使用本模块，依赖路径为 `file:../toast-kit`。

然后在工程根目录执行：

```sh
ohpm install --all
```

**OHPM 方式**：

```sh
ohpm install @monkey0803/toast-kit
```

**从源码构建 HAR**（独立仓库根目录）：

```sh
devecocli build
# 或
hvigorw --mode module -p module=toast_kit@default -p product=default assembleHar -p buildMode=release
```

产物位于 `library/build/default/outputs/default/`。


### 2. 初始化（一次）

主 UIAbility：

```ts
import { Toast } from '@monkey0803/toast-kit';

onWindowStageCreate(windowStage: window.WindowStage): void {
  windowStage.loadContent('pages/Index', (err) => {
    if (err.code) {
      return;
    }
    Toast.init(windowStage);
  });
}
```

`init` 可以重复调用（接续恢复 / 窗口重建）。

### 3. 使用

```ts
import { Toast } from '@monkey0803/toast-kit';

Toast.show($r('app.string.saved'));
Toast.show('Saved', { duration: 3000 });
Toast.show($r('app.string.offline_full'), { bottom: '100vp' });
```

显式指定上下文（多窗口场景）：

```ts
Toast.showIn(uiContext, $r('app.string.saved'));
```

### 4. UIExtensionAbility / 无 windowStage 页面

在页面生命周期中挂载 / 卸载：

```ts
import { Toast } from '@monkey0803/toast-kit';

aboutToAppear(): void {
  Toast.attach(this.getUIContext());
}

aboutToDisappear(): void {
  Toast.detach(this.getUIContext());
}
```

后挂载的上下文优先；同一个 `UIContext` 重复挂载会累计引用计数，`detach` 时递减，归零才移除。

### 5. 宿主增强（可选）

例如注入 HDS 沉浸光感材质：

```ts
import { promptAction } from '@kit.ArkUI';
import { Toast } from '@monkey0803/toast-kit';
import { appSettings } from '../model/AppSettings';
import { MaterialController } from '../service/MaterialController';

Toast.configure({
  enhance: (options: promptAction.ShowToastOptions): promptAction.ShowToastOptions => {
    return MaterialController.toastOptions(options, appSettings.immersiveOn);
  }
});
```

`enhance` 在每次 `show` 时执行，适合读取实时设置。重复调用 `configure` 只覆盖传入字段。

## API

| API | 说明 |
| --- | --- |
| `Toast.init(windowStage)` | 主 Ability 初始化；惰性解析主窗口 UIContext |
| `Toast.attach(uiContext)` | 手动挂载 UIContext（UIExtension 页面） |
| `Toast.detach(uiContext)` | 卸载 UIContext |
| `Toast.release()` | 清空全部缓存（Ability `onDestroy`） |
| `Toast.configure(config)` | 全局默认时长 / 底部距离 / enhance 装饰器 |
| `Toast.show(message, options?)` | 使用当前激活上下文弹提示 |
| `Toast.showIn(uiContext, message, options?)` | 在指定上下文弹提示 |

`ToastOptions`：`duration`、`bottom`、`showMode`、`alignment`、`offset`。

## 注意事项

- 必须在 UI 线程调用；库不做线程切换。
- 未初始化且未 attach 时，`show` 只告警一次并静默返回。
- 未显式配置 `duration` / `bottom` 时不覆盖系统默认值。
- 库不包含任何 UI 组件与状态管理装饰器，可与 V1 / V2 工程共存。
