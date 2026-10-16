/*
 * List.test.ets — 本地单元测试套件入口（聚合各测试文件）。
 *
 * 覆盖 Reader 正文提取管线的纯函数：HTML 解析 / 净化 / 主容器提取 / feed 解析 / 图片 mime 嗅探。
 */

import htmlDomTest from './HtmlDom.test';
import htmlSanitizerTest from './HtmlSanitizer.test';
import readabilityTest from './Readability.test';
import rssParserTest from './RssParser.test';
import mimeSniffTest from './MimeSniff.test';

export default function testsuite() {
  htmlDomTest();
  htmlSanitizerTest();
  readabilityTest();
  rssParserTest();
  mimeSniffTest();
}
