/*
 * List.test.ets — 单元测试套件入口（聚合各测试文件）。
 *
 * 覆盖 Reader 正文提取管线的纯函数（HTML 解析 / 净化 / 主容器提取 / feed 解析 / 图片 mime 嗅探），
 * 以及阅读排版档位与 Reader CSS 生成。
 */

import htmlDomTest from './HtmlDom.test';
import htmlSanitizerTest from './HtmlSanitizer.test';
import readabilityTest from './Readability.test';
import rssParserTest from './RssParser.test';
import mimeSniffTest from './MimeSniff.test';
import readerTypographyTest from './ReaderTypography.test';
import readerBudgetTest from './ReaderBudget.test';

export default function testsuite() {
  htmlDomTest();
  htmlSanitizerTest();
  readabilityTest();
  rssParserTest();
  mimeSniffTest();
  readerTypographyTest();
  readerBudgetTest();
}
