/*
 * EnclosureCodec.ets — enclosure 的持久化编解码与时长解析（纯函数，可单测）。
 *
 * 落库格式（紧凑 JSON，减少列表查询体积）：
 *   [{"u":"https://…mp3","t":"audio/mpeg","l":123456,"d":3210}]
 * 解码时逐字段做类型校验；损坏 / 旧数据一律返回空数组，绝不影响文章读取。
 */

import { Enclosure } from '../model/Enclosure';

/** 落盘结构。 */
interface EnclosureRecord {
  u?: string;
  t?: string;
  l?: number;
  d?: number;
}

/** 编码；空数组返回 '[]'。 */
export function encodeEnclosures(list: Enclosure[]): string {
  const records: EnclosureRecord[] = [];
  for (let i = 0; i < list.length; i += 1) {
    const item: Enclosure = list[i];
    if (item.url.length === 0) {
      continue;
    }
    records.push({ u: item.url, t: item.type, l: item.length, d: item.duration });
  }
  return JSON.stringify(records);
}

/** 解码；非法 JSON / 非数组 / 空 URL 一律丢弃。 */
export function decodeEnclosures(text: string): Enclosure[] {
  if (text.length === 0) {
    return [];
  }
  try {
    const records: EnclosureRecord[] = JSON.parse(text) as EnclosureRecord[];
    if (!Array.isArray(records)) {
      return [];
    }
    const result: Enclosure[] = [];
    for (let i = 0; i < records.length; i += 1) {
      const record: EnclosureRecord = records[i];
      const url: string = typeof record.u === 'string' ? record.u : '';
      if (url.length === 0) {
        continue;
      }
      const type: string = typeof record.t === 'string' ? record.t : '';
      const length: number = typeof record.l === 'number' && record.l > 0 ? record.l : 0;
      const duration: number = typeof record.d === 'number' && record.d > 0 ? record.d : 0;
      result.push(new Enclosure(url, type, length, duration));
    }
    return result;
  } catch (err) {
    return [];
  }
}

/**
 * 时长文本 → 秒。
 * 支持：纯数字秒（"3210"）、"mm:ss"、"hh:mm:ss"（itunes:duration 常见三种写法）。
 * 非法 / 空串返回 0。
 */
export function durationFromText(text: string): number {
  const value: string = text.trim();
  if (value.length === 0) {
    return 0;
  }
  const parts: string[] = value.split(':');
  let total: number = 0;
  for (let i = 0; i < parts.length; i += 1) {
    const part: string = parts[i].trim();
    if (part.length === 0) {
      return 0;
    }
    const number: number = Number(part);
    if (!Number.isFinite(number) || number < 0) {
      return 0;
    }
    total = total * 60 + Math.floor(number);
  }
  return total;
}

/** 数字文本 → 非负整数（长度 / 时长属性用）；非法返回 0。 */
export function numberFromText(text: string): number {
  const value: string = text.trim();
  if (value.length === 0) {
    return 0;
  }
  const number: number = Number(value);
  return Number.isFinite(number) && number > 0 ? Math.floor(number) : 0;
}
