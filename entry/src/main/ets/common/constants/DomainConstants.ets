/*
 * DomainConstants.ets — 领域开关（纯逻辑常量）。
 *
 * 基模板默认关闭图片领域模块；`--domain image` 时该文件会被 application-image/ 覆盖为 true，
 * 并同时替换 ImageTabView 与补上 ImageSupport / ImageViewModel。关闭时图片页签不渲染，
 * 包体也不引用 ImageKit。
 */
export const IMAGE_DOMAIN: boolean = false;
