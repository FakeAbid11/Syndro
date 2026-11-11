import assert from "node:assert/strict";
import { test } from "node:test";
import { CODE_ALPHABET, CODE_LENGTH, createCode, groupCode } from "../main/code";
import { createShareToken } from "../main/server";

const VALID = /^[A-HJ-NP-Z2-9]{8}$/;

test("codes use the unambiguous LinkPhone alphabet", () => {
  assert.equal(CODE_LENGTH, 8);
  assert.equal(CODE_ALPHABET.length, 32);
  assert.doesNotMatch(CODE_ALPHABET, /[IO01]/);

  for (let index = 0; index < 200; index += 1) {
    assert.match(createCode(), VALID);
  }
});

test("share tokens are eight-character codes, not hex", () => {
  const token = createShareToken();
  assert.match(token, VALID);
});

test("codes are grouped in the middle for display", () => {
  assert.equal(groupCode("ABCD2345"), "ABCD 2345");
  assert.equal(groupCode("SHORT"), "SHORT");
});
