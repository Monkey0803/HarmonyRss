import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const document = JSON.parse(readFileSync(resolve('catalog/feeds.json'), 'utf8'));
if (document.version !== 1 || !Array.isArray(document.feeds) || document.feeds.length < 30) {
  throw new Error('Invalid catalog version or feed list');
}
const categories = new Set(['tech', 'design', 'business', 'science', 'indie', 'cn']);
const keys = new Set();
for (const feed of document.feeds) {
  if (typeof feed.title !== 'string' || !feed.title.trim() || feed.title.length > 100 ||
    typeof feed.feedUrl !== 'string' || typeof feed.siteUrl !== 'string' ||
    !feed.feedUrl.startsWith('https://') || !feed.siteUrl.startsWith('https://') ||
    !categories.has(feed.category) || !Array.isArray(feed.tags) || feed.tags.length > 12 ||
    feed.tags.some(tag => typeof tag !== 'string' || !tag.trim()) ||
    typeof feed.popularity !== 'number' || feed.popularity < 0 || feed.popularity > 100) {
    throw new Error(`Invalid catalog item: ${feed.title}`);
  }
  const url = new URL(feed.feedUrl);
  const key = `${url.hostname.replace(/^www\./, '').toLowerCase()}${url.pathname.replace(/\/+$/, '')}${url.search}`;
  if (keys.has(key)) throw new Error(`Duplicate feed: ${feed.feedUrl}`);
  keys.add(key);
}
const builtin = readFileSync(resolve('entry/src/main/ets/model/Discover.ets'), 'utf8');
for (const feed of document.feeds) {
  if (!builtin.includes(`'${feed.feedUrl}'`)) throw new Error(`Missing built-in fallback: ${feed.feedUrl}`);
}
if (process.argv.includes('--network')) {
  const failed = [];
  for (let index = 0; index < document.feeds.length; index += 8) {
    await Promise.all(document.feeds.slice(index, index + 8).map(async feed => {
      try {
        const response = await fetch(feed.feedUrl, {
          headers: { Accept: 'application/rss+xml, application/atom+xml, application/feed+json, */*' },
          signal: AbortSignal.timeout(10000),
        });
        const body = await response.text();
        if (!response.ok || !/<rss\b|<feed\b|<rdf:RDF\b|"version"\s*:\s*"https:\/\/jsonfeed\.org\//i.test(body)) {
          failed.push(`${feed.title}: HTTP ${response.status} or invalid feed`);
        }
      } catch (error) {
        failed.push(`${feed.title}: ${error.message}`);
      }
    }));
  }
  if (failed.length) throw new Error(failed.join('\n'));
}
console.log(`Catalog valid: ${document.feeds.length} feeds`);
