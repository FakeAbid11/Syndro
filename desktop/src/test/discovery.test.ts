import assert from "node:assert/strict";
import { test } from "node:test";
import {
  PROTOCOL_VERSION,
  SERVICE_TYPE,
  serviceConfig,
} from "../main/discovery";

test("mDNS advertises location and identity without leaking the share code", () => {
  const config = serviceConfig({
    id: "8d280388-b403-4775-8807-93a9b488fc72",
    name: "desk",
    port: 47821,
  });

  assert.equal(config.type, SERVICE_TYPE);
  assert.equal(config.protocol, "tcp");
  assert.equal(config.port, 47821);
  assert.deepEqual(config.txt, {
    id: "8d280388-b403-4775-8807-93a9b488fc72",
    name: "desk",
    ver: PROTOCOL_VERSION,
  });
  assert.equal(Object.hasOwn(config.txt ?? {}, "token"), false);
});
