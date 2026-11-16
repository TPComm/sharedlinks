import { expect, test } from "bun:test";
import { landingPage } from "../../src/landing.ts";

test("landing links honor the configured app and escape page metadata", () => {
  const html = landingPage({
    appScheme: "custom-links",
    appStoreId: "123456789",
    publicUrl: 'https://links.example.com/\"><script>alert(1)</script>',
  });
  expect(html).toContain('href="custom-links://inbox"');
  expect(html).toContain('href="https://apps.apple.com/app/id123456789"');
  expect(html).toContain('content="app-id=123456789, app-argument=custom-links://inbox"');
  expect(html).toContain("https://links.example.com/&#34;&#62;&#60;script&#62;");
  expect(html).not.toContain("<script>");
});
