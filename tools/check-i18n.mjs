#!/usr/bin/env node
/*
 * check-i18n.mjs — 多语言资源一致性校验。
 *
 * 以 base/element/string.json 为基准，检查每个语言目录是否：
 *   1. 覆盖全部 key（不缺、不多）；
 *   2. 没有重复 key；
 *   3. 占位符（%d / %s / %f / %% / %1$s）与基准一致（种类与数量）。
 *
 * 用法：node tools/check-i18n.mjs
 * 退出码：0 全部通过；1 存在差异（会打印前 20 条）。
 */

import { readFileSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const LOCALES = ['zh_CN', 'zh_Hant', 'ja', 'de', 'fr', 'es'];

function load(locale) {
  const file = `${ROOT}entry/src/main/resources/${locale}/element/string.json`;
  const data = JSON.parse(readFileSync(file, 'utf8'));
  return data.string ?? [];
}

function exists(locale) {
  try {
    return statSync(`${ROOT}entry/src/main/resources/${locale}/element/string.json`).isFile();
  } catch (err) {
    return false;
  }
}

function holders(value) {
  const found = value.match(/%(?:\d+\$)?[dsf]|%%/g);
  return (found === null ? [] : found).sort().join(',');
}

function main() {
  const base = load('base');
  const baseNames = base.map((entry) => entry.name);
  const baseSet = new Set(baseNames);
  const baseBy = new Map(base.map((entry) => [entry.name, entry.value]));
  const locales = LOCALES.filter(exists);
  if (locales.length === 0) {
    console.error('no locale directory found');
    process.exit(2);
  }
  let failed = false;
  for (const locale of locales) {
    const entries = load(locale);
    const names = entries.map((entry) => entry.name);
    const seen = new Set(names);
    const duplicated = [...new Set(names.filter((name, index) => names.indexOf(name) !== index))];
    const missingKeys = baseNames.filter((name) => !seen.has(name));
    const extraKeys = names.filter((name) => !baseSet.has(name));
    const missingValues = entries.filter((entry) => typeof entry.value !== 'string').map((entry) => entry.name);
    const badPlaceholders = [];
    for (const entry of entries) {
      const expected = baseBy.get(entry.name);
      if (expected !== undefined && holders(expected) !== holders(entry.value)) {
        badPlaceholders.push(`${entry.name} (${holders(expected)} → ${holders(entry.value)})`);
      }
    }
    const problems = missingKeys.length + extraKeys.length + duplicated.length +
      missingValues.length + badPlaceholders.length;
    if (missingKeys.length > 0) {
      console.log(`[${locale}] 缺少 ${missingKeys.length} 个 key：${missingKeys.slice(0, 20).join(', ')}`);
    }
    if (extraKeys.length > 0) {
      console.log(`[${locale}] 多出 ${extraKeys.length} 个 key：${extraKeys.slice(0, 20).join(', ')}`);
    }
    if (duplicated.length > 0) {
      console.log(`[${locale}] 重复 key ${duplicated.length} 个：${duplicated.slice(0, 20).join(', ')}`);
    }
    if (missingValues.length > 0) {
      console.log(`[${locale}] 缺少 value ${missingValues.length} 处：${missingValues.slice(0, 20).join(', ')}`);
    }
    if (badPlaceholders.length > 0) {
      console.log(`[${locale}] 占位符不一致 ${badPlaceholders.length} 处：${badPlaceholders.slice(0, 20).join('; ')}`);
    }
    if (problems === 0) {
      console.log(`${locale}: ok (${seen.size} keys)`);
    } else {
      failed = true;
    }
  }
  if (failed) {
    process.exit(1);
  }
}

main();
