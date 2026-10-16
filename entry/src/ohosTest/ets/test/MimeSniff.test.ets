/*
 * MimeSniff.test.ets — 图片魔数嗅探单测。
 */

import { describe, it, expect } from '@ohos/hypium';
import { sniffMime, guessMime } from '../../../main/ets/service/MimeSniff';

function bytes(values: number[]): Uint8Array {
  const out: Uint8Array = new Uint8Array(values.length);
  for (let i = 0; i < values.length; i += 1) {
    out[i] = values[i];
  }
  return out;
}

function ascii(text: string, padTo: number = 0): Uint8Array {
  const length: number = text.length > padTo ? text.length : padTo;
  const out: Uint8Array = new Uint8Array(length);
  for (let i = 0; i < text.length; i += 1) {
    out[i] = text.charCodeAt(i);
  }
  return out;
}

export default function mimeSniffTest() {
  describe('MimeSniff', () => {
    it('detects_jpeg', 0, () => {
      expect(sniffMime(bytes([0xFF, 0xD8, 0xFF, 0xE0]), 'x')).assertEqual('image/jpeg');
    });

    it('detects_png', 0, () => {
      expect(sniffMime(bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), 'x')).assertEqual('image/png');
    });

    it('detects_gif', 0, () => {
      expect(sniffMime(ascii('GIF89a'), 'x')).assertEqual('image/gif');
    });

    it('detects_webp', 0, () => {
      // RIFF????WEBP
      const header: Uint8Array = new Uint8Array(12);
      header[0] = 0x52;
      header[1] = 0x49;
      header[2] = 0x46;
      header[3] = 0x46;
      header[8] = 0x57;
      header[9] = 0x45;
      header[10] = 0x42;
      header[11] = 0x50;
      expect(sniffMime(header, 'x')).assertEqual('image/webp');
    });

    it('detects_avif', 0, () => {
      // ????ftypavif
      const header: Uint8Array = ascii('AAAAftypavif');
      expect(sniffMime(header, 'x')).assertEqual('image/avif');
    });

    it('detects_heic', 0, () => {
      expect(sniffMime(ascii('AAAAftypheic'), 'x')).assertEqual('image/heic');
    });

    it('falls_back_to_url_suffix', 0, () => {
      expect(sniffMime(bytes([0x00, 0x01, 0x02]), 'https://x/y.png')).assertEqual('image/png');
      expect(sniffMime(bytes([0x00, 0x01, 0x02]), 'https://x/y')).assertEqual('image/jpeg');
    });

    it('guess_mime_by_suffix', 0, () => {
      expect(guessMime('a.webp')).assertEqual('image/webp');
      expect(guessMime('a.avif')).assertEqual('image/avif');
      expect(guessMime('a.unknown')).assertEqual('image/jpeg');
    });
  });
}
