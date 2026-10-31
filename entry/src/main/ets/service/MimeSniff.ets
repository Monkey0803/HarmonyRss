/*
 * MimeSniff.ets — 按文件魔数嗅探图片 MIME（无任何依赖，便于单测）。
 *
 * 必须嗅探而不能只看 URL：很多站点返回 AVIF/WebP（URL 常无扩展名），
 * 若 data URI 的 mime 与实际内容不符，浏览器解码会失败（破图）。
 */

/** 由 URL 后缀猜 mime（拿不到内容时的兜底）。 */
export function guessMime(url: string): string {
  const lower: string = url.toLowerCase();
  if (lower.indexOf('.png') >= 0) {
    return 'image/png';
  }
  if (lower.indexOf('.gif') >= 0) {
    return 'image/gif';
  }
  if (lower.indexOf('.webp') >= 0) {
    return 'image/webp';
  }
  if (lower.indexOf('.svg') >= 0) {
    return 'image/svg+xml';
  }
  if (lower.indexOf('.avif') >= 0) {
    return 'image/avif';
  }
  return 'image/jpeg';
}

function asciiAt(bytes: Uint8Array, start: number, text: string): boolean {
  for (let i = 0; i < text.length; i += 1) {
    if (bytes[start + i] !== text.charCodeAt(i)) {
      return false;
    }
  }
  return true;
}

/** 离线缓存只接受内容可识别的图片，避免把站点错误页按 URL 后缀存成图片。 */
export function verifiedImageMime(bytes: Uint8Array): string {
  if (bytes.length >= 3 && bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 && bytes[0] === 0x89 && asciiAt(bytes, 1, 'PNG') &&
    bytes[4] === 0x0D && bytes[5] === 0x0A && bytes[6] === 0x1A && bytes[7] === 0x0A) {
    return 'image/png';
  }
  if (bytes.length >= 6 && (asciiAt(bytes, 0, 'GIF87a') || asciiAt(bytes, 0, 'GIF89a'))) {
    return 'image/gif';
  }
  if (bytes.length >= 12 && asciiAt(bytes, 0, 'RIFF') && asciiAt(bytes, 8, 'WEBP')) {
    return 'image/webp';
  }
  if (bytes.length >= 12 && asciiAt(bytes, 4, 'ftyp')) {
    if (asciiAt(bytes, 8, 'heic') || asciiAt(bytes, 8, 'heix')) {
      return 'image/heic';
    }
    if (asciiAt(bytes, 8, 'avif') || asciiAt(bytes, 8, 'avis')) {
      return 'image/avif';
    }
  }
  return '';
}

/** 按文件魔数嗅探真实 mime；无法识别时退回按 URL 后缀猜（非缓存用途）。 */
export function sniffMime(bytes: Uint8Array, url: string): string {
  const verified: string = verifiedImageMime(bytes);
  if (verified.length > 0) {
    return verified;
  }
  return guessMime(url);
}
