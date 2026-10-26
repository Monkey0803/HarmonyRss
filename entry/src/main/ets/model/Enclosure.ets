/*
 * Enclosure.ets — feed 附带的媒体（播客音频 / 视频）。
 *
 * RSS: <enclosure url type length> + <itunes:duration>
 * Atom: <link rel="enclosure" href type length>
 * Media RSS: <media:content url type duration>
 * JSON Feed: attachments[]（url / mime_type / size_in_bytes / duration_in_seconds）
 *
 * 类型缺失时按 URL 后缀兜底（很多播客源的 enclosure 不带 type）。
 */

/** 媒体大类。 */
export enum MediaKind {
  AUDIO = 'audio',
  VIDEO = 'video',
  IMAGE = 'image',
  OTHER = 'other'
}

const AUDIO_EXTENSIONS: string[] = [
  '.mp3', '.m4a', '.aac', '.ogg', '.oga', '.opus', '.wav', '.flac', '.m4b'
];
const VIDEO_EXTENSIONS: string[] = [
  '.mp4', '.m4v', '.webm', '.mov', '.mkv', '.avi'
];

/** 取 URL 的扩展名（不含 query / fragment，小写）。 */
export function extensionOf(url: string): string {
  const lower: string = url.toLowerCase();
  const query: number = lower.indexOf('?');
  const clean: string = query >= 0 ? lower.substring(0, query) : lower;
  const slash: number = clean.lastIndexOf('/');
  const name: string = slash >= 0 ? clean.substring(slash + 1) : clean;
  const dot: number = name.lastIndexOf('.');
  return dot >= 0 ? name.substring(dot) : '';
}

/** 判断媒体大类：mime 优先，缺失 / 泛型时看后缀。 */
export function mediaKindOf(type: string, url: string): string {
  const mime: string = type.toLowerCase().trim();
  if (mime.startsWith('audio/') || mime === 'audio') {
    return MediaKind.AUDIO;
  }
  if (mime.startsWith('video/') || mime === 'video') {
    return MediaKind.VIDEO;
  }
  if (mime.startsWith('image/')) {
    return MediaKind.IMAGE;
  }
  const ext: string = extensionOf(url);
  if (AUDIO_EXTENSIONS.indexOf(ext) >= 0) {
    return MediaKind.AUDIO;
  }
  if (VIDEO_EXTENSIONS.indexOf(ext) >= 0) {
    return MediaKind.VIDEO;
  }
  return MediaKind.OTHER;
}

/** 秒 → 「mm:ss」/「h:mm:ss」；非法值显示 0:00。 */
export function formatDuration(seconds: number): string {
  const total: number = Number.isFinite(seconds) && seconds > 0 ? Math.floor(seconds) : 0;
  const hours: number = Math.floor(total / 3600);
  const minutes: number = Math.floor((total % 3600) / 60);
  const secs: number = total % 60;
  const secText: string = secs < 10 ? '0' + secs.toString() : secs.toString();
  if (hours > 0) {
    const minText: string = minutes < 10 ? '0' + minutes.toString() : minutes.toString();
    return hours.toString() + ':' + minText + ':' + secText;
  }
  return minutes.toString() + ':' + secText;
}

/** 第一个音频附件；没有返回 undefined。 */
export function firstAudio(list: Enclosure[]): Enclosure | undefined {
  for (let i = 0; i < list.length; i += 1) {
    if (list[i].isAudio()) {
      return list[i];
    }
  }
  return undefined;
}

/** 第一个视频附件；没有返回 undefined。 */
export function firstVideo(list: Enclosure[]): Enclosure | undefined {
  for (let i = 0; i < list.length; i += 1) {
    if (list[i].isVideo()) {
      return list[i];
    }
  }
  return undefined;
}

/** 一个媒体附件。 */
export class Enclosure {
  readonly url: string;
  /** MIME；空串表示 feed 没给（由 URL 后缀兜底判断）。 */
  readonly type: string;
  /** 字节大小；0 表示未知。 */
  readonly length: number;
  /** 时长（秒）；0 表示未知。 */
  readonly duration: number;

  constructor(url: string, type: string = '', length: number = 0, duration: number = 0) {
    this.url = url;
    this.type = type;
    this.length = length;
    this.duration = duration;
  }

  kind(): string {
    return mediaKindOf(this.type, this.url);
  }

  isAudio(): boolean {
    return this.kind() === MediaKind.AUDIO;
  }

  isVideo(): boolean {
    return this.kind() === MediaKind.VIDEO;
  }
}
