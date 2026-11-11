import { randomBytes } from "node:crypto";

/**
 * The pairing-code alphabet used by LinkPhone: A-Z without I and O, plus 2-9.
 * Dropping the ambiguous glyphs makes a code safe to read aloud or type from a
 * screen without confusing 0/O, 1/I or 5/S.
 */
export const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
export const CODE_LENGTH = 8;

/** 8 symbols = 40 bits. 256 is a multiple of 32, so masking is unbiased. */
export function createCode(): string {
  return Array.from(randomBytes(CODE_LENGTH), (byte) => CODE_ALPHABET[byte & 31]).join("");
}

/** `ABCD2345` -> `ABCD 2345`, matching how the code is shown on screen. */
export function groupCode(code: string): string {
  return code.length === CODE_LENGTH ? `${code.slice(0, 4)} ${code.slice(4)}` : code;
}
