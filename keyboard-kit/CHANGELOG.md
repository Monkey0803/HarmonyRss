# Changelog

## 1.0.0 (2026-11-04)

- 首个版本。
- 提供 `Keyboard.init / attach / detach / release` 上下文生命周期。
- 提供 `Keyboard.dismiss` 收起软键盘、`Keyboard.requestFocus` 请求输入框焦点。
- 提供 `Keyboard.avoidResize / pushAvoidMode / popAvoidMode`，按 `UIContext` 维护避让模式栈。
- 支持主 UIAbility 与 UIExtensionAbility（分享页）两种接入方式。
