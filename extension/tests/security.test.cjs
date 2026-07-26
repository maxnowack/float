const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

require("../dist/security.js");

const vector = JSON.parse(
  fs.readFileSync(
    path.join(__dirname, "../../protocol/test-vectors/hmac-v2.json"),
    "utf8",
  ),
);

test("matches the shared canonical HMAC vector", async () => {
  const canonical = FloatSecurity.canonicalAuthenticationInput(
    vector.origin,
    vector.nonce,
  );
  assert.equal(Buffer.from(canonical).toString("hex"), vector.canonicalHex);
  assert.equal(
    await FloatSecurity.authenticationProof(
      vector.secret,
      vector.origin,
      vector.nonce,
    ),
    vector.proof,
  );
});

test("persists and removes the pairing credential", async () => {
  let storedValue;
  const store = {
    async load() {
      return storedValue;
    },
    async save(value) {
      storedValue = value;
    },
    async remove() {
      storedValue = undefined;
    },
  };
  const repository = new FloatSecurity.PairingCredentialRepository(store);
  assert.equal(await repository.load(), null);
  await repository.save(vector.secret);
  assert.equal(await repository.load(), vector.secret);
  await repository.remove();
  assert.equal(await repository.load(), null);
  await assert.rejects(() => repository.save("not-a-secret"));
});

test("keeps credential persistence outside content-script capabilities", () => {
  for (const manifestName of ["manifest.chrome.json", "manifest.firefox.json"]) {
    const manifest = JSON.parse(
      fs.readFileSync(path.join(__dirname, "..", manifestName), "utf8"),
    );
    assert.equal(manifest.permissions.includes("storage"), false);
    for (const contentScript of manifest.content_scripts) {
      assert.equal(contentScript.js.includes("dist/security.js"), false);
    }
  }

  const contentSource = fs.readFileSync(
    path.join(__dirname, "../src/content_script.ts"),
    "utf8",
  );
  assert.equal(contentSource.includes("PairingCredentialRepository"), false);
  assert.equal(contentSource.includes("float:pairing:"), false);
});

test("trusts only the exact packaged pairing page across browser sender shapes", () => {
  const extensionId = "float@maxnowack.dev";
  const popupUrl = "moz-extension://example-uuid/popup.html";
  const cases = [
    [{ id: extensionId, url: popupUrl }, true],
    [{ id: extensionId, url: popupUrl, tab: { id: 42 } }, true],
    [{ id: extensionId, url: "https://example.com/" }, false],
    [{ id: "other-extension", url: popupUrl }, false],
    [{ id: extensionId, url: "moz-extension://example-uuid/manifest.json" }, false],
  ];

  for (const [sender, expected] of cases) {
    assert.equal(
      FloatSecurity.isTrustedExtensionPageSender(sender, extensionId, popupUrl),
      expected,
    );
  }
});

test("coalesces and bounds pending protocol messages by count and bytes", () => {
  const queue = new FloatSecurity.BoundedProtocolMessageQueue(3, 512, 2);
  assert.equal(queue.enqueue({ type: "state", tabs: [{ tabId: 1 }] }), true);
  assert.equal(queue.enqueue({ type: "state", tabs: [{ tabId: 2 }] }), true);
  assert.equal(queue.count, 1);
  assert.deepEqual(queue.drain(), [
    { type: "state", tabs: [{ tabId: 2 }] },
  ]);
  assert.equal(queue.byteCount, 0);

  assert.equal(
    queue.enqueue({ type: "offer", tabId: 1, videoId: "video", generation: 1 }),
    true,
  );
  assert.equal(
    queue.enqueue({ type: "ice", tabId: 1, videoId: "video", generation: 1 }),
    true,
  );
  assert.equal(
    queue.enqueue({ type: "ice", tabId: 1, videoId: "video", generation: 2 }),
    false,
  );
  assert.equal(
    queue.enqueue({ type: "offer", tabId: 1, videoId: "video", generation: 2 }),
    true,
  );
  assert.deepEqual(queue.drain(), [
    { type: "offer", tabId: 1, videoId: "video", generation: 2 },
  ]);

  const byteBounded = new FloatSecurity.BoundedProtocolMessageQueue(10, 96, 2);
  for (let index = 0; index < 100; index += 1) {
    byteBounded.enqueue({ type: "error", reason: `error-${index}` });
    assert.ok(byteBounded.count <= 10);
    assert.ok(byteBounded.byteCount <= 96);
  }
  assert.equal(
    byteBounded.enqueue({ type: "error", reason: "x".repeat(96) }),
    false,
  );
  const cyclic = { type: "error" };
  cyclic.self = cyclic;
  assert.equal(byteBounded.enqueue(cyclic), false);

  const noOrphanIce = new FloatSecurity.BoundedProtocolMessageQueue(1, 512, 2);
  assert.equal(
    noOrphanIce.enqueue({
      type: "offer",
      tabId: 1,
      videoId: "video",
      generation: 1,
    }),
    true,
  );
  assert.equal(
    noOrphanIce.enqueue({
      type: "ice",
      tabId: 1,
      videoId: "video",
      generation: 1,
    }),
    false,
  );
  assert.deepEqual(noOrphanIce.drain(), []);
});

test("sends no application message before authentication", async () => {
  const session = new FloatSecurity.CompanionAuthenticationSession(
    vector.origin,
    vector.secret,
  );
  const invalid = await session.handle({ type: "hello", version: 2 });
  assert.equal(invalid.closeCode, 1008);
  assert.equal(session.isAuthenticated, false);
  assert.equal(invalid.send, undefined);
});

test("authenticates, reconnects, and reauthenticates with a fresh session", async () => {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const session = new FloatSecurity.CompanionAuthenticationSession(
      vector.origin,
      vector.secret,
    );
    const response = await session.handle({
      type: "authChallenge",
      version: 2,
      origin: vector.origin,
      nonce: vector.nonce,
    });
    assert.deepEqual(response.send, {
      type: "authResponse",
      version: 2,
      proof: vector.proof,
    });
    const result = await session.handle({
      type: "authResult",
      version: 2,
      authenticated: true,
    });
    assert.equal(result.authenticated, true);
    assert.equal(session.isAuthenticated, true);
  }
});

test("rejects an unpaired or malformed companion challenge", async () => {
  const unpaired = new FloatSecurity.CompanionAuthenticationSession(
    vector.origin,
    null,
  );
  const missingCredential = await unpaired.handle({
    type: "authChallenge",
    version: 2,
    origin: vector.origin,
    nonce: vector.nonce,
  });
  assert.equal(missingCredential.closeCode, 4001);
  assert.equal(missingCredential.status, "unpaired");

  const malformed = new FloatSecurity.CompanionAuthenticationSession(
    vector.origin,
    vector.secret,
  );
  const wrongOrigin = await malformed.handle({
    type: "authChallenge",
    version: 2,
    origin: "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    nonce: vector.nonce,
  });
  assert.equal(wrongOrigin.closeCode, 1008);
  assert.equal(wrongOrigin.send, undefined);
});

test("uses bounded reconnect delays and resets after authentication", () => {
  const backoff = new FloatSecurity.ReconnectBackoff();
  assert.deepEqual(
    Array.from({ length: 7 }, () => backoff.nextDelayMilliseconds()),
    [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000],
  );
  backoff.reset();
  assert.equal(backoff.nextDelayMilliseconds(), 1_000);
});
