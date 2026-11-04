# keyboard-kit

HarmonyOS 可复用软键盘（输入法）管理库。把「收起键盘」「请求焦点」「键盘避让模式切换」收敛到统一入口，调用方初始化一次后即可在任意位置使用，无需反复获取 `UIContext`。

- **OHPM**：`@monkey0803/keyboard-kit@1.0.0`
- **Gitee**：https://gitee.com/monkey0803/keyboard-kit

## 安装

```bash
ohpm install @monkey0803/keyboard-kit
```

> 发布包构建基线：HarmonyOS 6.1.0（API 23）。

## 特性

- 零上下文调用：`Keyboard.dismiss()` / `Keyboard.requestFocus('inputId')`
- 避让模式栈：按 `UIContext` 记录并恢复 `KeyboardAvoidMode`，支持嵌套进入 / 退出
- 自动容错：无 UI 上下文或系统 API 抛异常时只记日志，不影响业务
- 多 Ability / UIExtension 支持：`init(windowStage)` + `attach(uiContext)`
- 无业务依赖：库只依赖 `@kit.ArkUI` / `@kit.BasicServicesKit` / `@kit.PerformanceAnalysisKit`
- 无状态管理装饰器：普通静态类，可与 V1 / V2 工程共存

## 接入

### 1. 添加依赖

**Gitee 源码方式**（独立仓库 clone 后）：

```json5
// entry/oh-package.json5
{
  "dependencies": {
    "@monkey0803/keyboard-kit": "file:../keyboard-kit/library"
  }
}
```

> 若直接在 HarmonyRss 主工程内使用本模块，依赖路径为 `file:../keyboard-kit`。

然后在工程根目录执行：

```sh
ohpm install --all
```

**OHPM 方式**：

```sh
ohpm install @monkey0803/keyboard-kit
```


**从源码构建 HAR**（独立仓库根目录）：

```sh
devecocli build
# 或
hvigorw --mode module -p module=keyboard_kit@default -p product=default assembleHar -p buildMode=release
```

产物位于 `library/build/default/outputs/default/`。

### 2. 初始化（一次）

主 UIAbility：

```ts
import { Keyboard } from '@monkey0803/keyboard-kit';

onWindowStageCreate(windowStage: window.WindowStage): void {
  Keyboard.init(windowStage);
}
```

`init` 可以重复调用（重启恢复 / 窗口重建），会清空旧的窗口缓存与避让栈。

### 3. 使用

```ts
import { Keyboard } from '@monkey0803/keyboard-kit';

// 收起软键盘（例如点击其他控件、提交搜索时）
Keyboard.dismiss();

// 请求指定输入框焦点（组件需已设置 .id('inputId')）
Keyboard.requestFocus('inputId');

// 临时切换为 RESIZE 避让，必须与 popAvoidMode 成对调用
Keyboard.avoidResize();
Keyboard.popAvoidMode();
```

显式指定上下文（多窗口场景）：

```ts
Keyboard.dismissIn(uiContext);
Keyboard.requestFocusIn(uiContext, 'inputId');
Keyboard.pushAvoidMode(KeyboardAvoidMode.RESIZE, uiContext);
Keyboard.popAvoidMode(uiContext);
```

### 4. UIExtensionAbility / 无 windowStage 页面

在页面生命周期中挂载 / 卸载：

```ts
import { Keyboard } from '@monkey0803/keyboard-kit';

aboutToAppear(): void {
  Keyboard.attach(this.getUIContext());
}

aboutToDisappear(): void {
  Keyboard.detach(this.getUIContext());
}
```

后挂载的上下文优先；同一个 `UIContext` 重复挂载会累计引用计数，`detach` 时递减，归零才移除。

### 5. Ability 销毁

```ts
onDestroy(): void {
  Keyboard.release();
}
```

## API

| API | 说明 |
| --- | --- |
| `Keyboard.init(windowStage)` | 主 Ability 初始化；惰性解析主窗口 UIContext |
| `Keyboard.attach(uiContext)` | 手动挂载 UIContext（UIExtension 页面） |
| `Keyboard.detach(uiContext)` | 卸载 UIContext，并清理其避让栈 |
| `Keyboard.release()` | 清空全部缓存（Ability `onDestroy`） |
| `Keyboard.dismiss()` | 使用当前激活上下文收起软键盘 |
| `Keyboard.dismissIn(uiContext)` | 在指定上下文收起软键盘 |
| `Keyboard.requestFocus(componentId)` | 请求指定组件焦点 |
| `Keyboard.requestFocusIn(uiContext, componentId)` | 在指定上下文请求焦点 |
| `Keyboard.avoidResize(uiContext?)` | 压入 `KeyboardAvoidMode.RESIZE` |
| `Keyboard.pushAvoidMode(mode, uiContext?)` | 压入任意避让模式，并记录当前模式 |
| `Keyboard.popAvoidMode(uiContext?)` | 恢复上一次避让模式 |

## 注意事项

- 必须在 UI 线程调用；库不做线程切换。
- 未初始化且未 attach 时，键盘操作只告警一次并静默返回。
- `pushAvoidMode` / `avoidResize` 必须与 `popAvoidMode` 成对调用；页面销毁前应确保已恢复。
- `.enableKeyboardOnFocus(false)` 属于组件级属性，不属于本库的运行时调度范围。
- 外接键盘快捷键（`j/k/m/s`、`Esc` 等）属于独立能力，不在本库范围。
