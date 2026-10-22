import test from "node:test";
import assert from "node:assert/strict";
import { normalizeEmail } from "../src/auth.js";

test("normalizeEmail trims, lowercases, and removes whitespace", () => {
  assert.equal(normalizeEmail("  Test @Example.COM  "), "test@example.com");
});

test("normalizeEmail keeps one at-sign and removes other invalid characters", () => {
  assert.equal(normalizeEmail("a@@b.com<script>"), "a@b.comscript");
});

test("normalizeEmail preserves common valid local-part characters", () => {
  assert.equal(normalizeEmail("First.Last+tag@example.co.uk"), "first.last+tag@example.co.uk");
});
