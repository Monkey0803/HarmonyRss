# Changelog

## 1.0.0

- 新增 `Toast` 全局单例，支持 `Toast.show` / `Toast.showIn`。
- 支持多 Ability 与 Share Extension：`Keyboard` 无涉，Toast 通过 `init` / `attach` / `detach` 管理 UIContext。
- 支持 `Toast.configure` 注入宿主选项装饰器。
