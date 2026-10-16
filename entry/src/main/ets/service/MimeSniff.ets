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

/** 按文件魔数嗅探真实 mime；无法识别时退回按 URL 后缀猜。 */
export function sniffMime(bytes: Uint8Array, url: string): string {
  if (bytes.length >= 3 && bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 6 && asciiAt(bytes, 0, 'GIF')) {
    return 'image/gif';
  }
  if (bytes.length >= 12 && asciiAt(bytes, 0, 'RIFF') && asciiAt(bytes, 8, 'WEBP')) {
    return 'image/webp';
  }
  if (bytes.length >= 12 && asciiAt(bytes, 4, 'ftyp')) {
    if (asciiAt(bytes, 8, 'heic') || asciiAt(bytes, 8, 'heix') || asciiAt(bytes, 8, 'mif1')) {
      return 'image/heic';
    }
    return 'image/avif';
  }
  return guessMime(url);
}
