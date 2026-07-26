type PairingCredentialStore = {
  load(): Promise<unknown>;
  save(value: string): Promise<void>;
  remove(): Promise<void>;
};

type PairingStatus = "disconnected" | "unpaired" | "authenticating" | "connected";

type AuthenticationAction = {
  send?: Record<string, unknown>;
  closeCode?: number;
  status: PairingStatus;
  authenticated?: boolean;
};

const FLOAT_PAIRING_STORAGE_KEY = "floatPairingSecretV2";
const FLOAT_PAIRING_DATABASE_NAME = "float-security-v2";
const FLOAT_PAIRING_OBJECT_STORE = "credentials";
const FLOAT_SECRET_BYTES = 32;
const FLOAT_NONCE_BYTES = 32;

function encodeBase64URL(data: Uint8Array): string {
  let binary = "";
  data.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function decodeBase64URL(value: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]+$/.test(value) || value.length % 4 === 1) {
    return null;
  }
  const padding = value.length % 4 === 0 ? "" : "=".repeat(4 - (value.length % 4));
  try {
    const binary = atob(value.replace(/-/g, "+").replace(/_/g, "/") + padding);
    const result = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      result[index] = binary.charCodeAt(index);
    }
    return result;
  } catch {
    return null;
  }
}

function canonicalAuthenticationInput(origin: string, nonce: string): Uint8Array {
  return new TextEncoder().encode(
    `Float-Pairing-V2\nversion=2\norigin=${origin}\nnonce=${nonce}\n`,
  );
}

async function authenticationProof(
  encodedSecret: string,
  origin: string,
  nonce: string,
): Promise<string> {
  const secret = decodeBase64URL(encodedSecret);
  if (!secret || secret.byteLength !== FLOAT_SECRET_BYTES) {
    throw new Error("Pairing secret must encode exactly 32 bytes");
  }
  const nonceBytes = decodeBase64URL(nonce);
  if (!nonceBytes || nonceBytes.byteLength !== FLOAT_NONCE_BYTES) {
    throw new Error("Authentication nonce is invalid");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    secret,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const proof = await crypto.subtle.sign(
    "HMAC",
    key,
    canonicalAuthenticationInput(origin, nonce),
  );
  return encodeBase64URL(new Uint8Array(proof));
}

function validatePairingSecret(value: string): boolean {
  return decodeBase64URL(value)?.byteLength === FLOAT_SECRET_BYTES;
}

function randomHandshakeSubprotocol(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return `float-v2.${encodeBase64URL(bytes)}`;
}

function isTrustedExtensionPageSender(
  sender: unknown,
  expectedExtensionId: string,
  expectedPageUrl: string,
): boolean {
  if (!sender || typeof sender !== "object") {
    return false;
  }
  const record = sender as Record<string, unknown>;
  return record.id === expectedExtensionId && record.url === expectedPageUrl;
}

class PairingCredentialRepository {
  constructor(private readonly store: PairingCredentialStore) {}

  async load(): Promise<string | null> {
    const value = await this.store.load();
    return typeof value === "string" && validatePairingSecret(value) ? value : null;
  }

  async save(value: string): Promise<void> {
    if (!validatePairingSecret(value)) {
      throw new Error("Pairing secret must be an unpadded base64url 32-byte value");
    }
    await this.store.save(value);
  }

  async remove(): Promise<void> {
    await this.store.remove();
  }
}

class IndexedDBPairingCredentialStore implements PairingCredentialStore {
  constructor(private readonly databaseFactory: IDBFactory) {}

  async load(): Promise<unknown> {
    const database = await this.openDatabase();
    try {
      return await new Promise<unknown>((resolve, reject) => {
        const transaction = database.transaction(
          FLOAT_PAIRING_OBJECT_STORE,
          "readonly",
        );
        const request = transaction
          .objectStore(FLOAT_PAIRING_OBJECT_STORE)
          .get(FLOAT_PAIRING_STORAGE_KEY);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error ?? new Error("Credential read failed"));
      });
    } finally {
      database.close();
    }
  }

  async save(value: string): Promise<void> {
    await this.write((store) => store.put(value, FLOAT_PAIRING_STORAGE_KEY));
  }

  async remove(): Promise<void> {
    await this.write((store) => store.delete(FLOAT_PAIRING_STORAGE_KEY));
  }

  private async write(
    operation: (store: IDBObjectStore) => IDBRequest,
  ): Promise<void> {
    const database = await this.openDatabase();
    try {
      await new Promise<void>((resolve, reject) => {
        const transaction = database.transaction(
          FLOAT_PAIRING_OBJECT_STORE,
          "readwrite",
        );
        transaction.oncomplete = () => resolve();
        transaction.onerror = () =>
          reject(transaction.error ?? new Error("Credential write failed"));
        transaction.onabort = () =>
          reject(transaction.error ?? new Error("Credential write aborted"));
        operation(transaction.objectStore(FLOAT_PAIRING_OBJECT_STORE));
      });
    } finally {
      database.close();
    }
  }

  private openDatabase(): Promise<IDBDatabase> {
    return new Promise<IDBDatabase>((resolve, reject) => {
      const request = this.databaseFactory.open(FLOAT_PAIRING_DATABASE_NAME, 1);
      request.onupgradeneeded = () => {
        const database = request.result;
        if (!database.objectStoreNames.contains(FLOAT_PAIRING_OBJECT_STORE)) {
          database.createObjectStore(FLOAT_PAIRING_OBJECT_STORE);
        }
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () =>
        reject(request.error ?? new Error("Credential database open failed"));
      request.onblocked = () => reject(new Error("Credential database open blocked"));
    });
  }
}

class BoundedProtocolMessageQueue {
  private readonly entries: Array<{ payload: unknown; bytes: number }> = [];
  private retainedBytes = 0;

  constructor(
    private readonly maximumCount: number,
    private readonly maximumBytes: number,
    private readonly protocolVersion: number,
  ) {
    if (maximumCount <= 0 || maximumBytes <= 0) {
      throw new Error("Queue limits must be positive");
    }
  }

  get count(): number {
    return this.entries.length;
  }

  get byteCount(): number {
    return this.retainedBytes;
  }

  enqueue(payload: unknown): boolean {
    const type = this.readType(payload);
    if (type === "debug") {
      return false;
    }

    if (type === "state") {
      this.removeWhere((entry) => this.readType(entry.payload) === "state");
    } else if (type === "offer") {
      this.removeWhere((entry) => {
        const entryType = this.readType(entry.payload);
        return entryType === "offer" || entryType === "ice";
      });
    } else if (type === "stop") {
      this.removeWhere((entry) => {
        const entryType = this.readType(entry.payload);
        return entryType === "offer" || entryType === "ice" || entryType === "stop";
      });
    } else if (type === "ice" && !this.hasMatchingQueuedOffer(payload)) {
      return false;
    }

    const bytes = this.serializedByteCount(payload);
    if (bytes === null || bytes > this.maximumBytes) {
      return false;
    }
    this.entries.push({ payload, bytes });
    this.retainedBytes += bytes;

    while (
      this.entries.length > this.maximumCount ||
      this.retainedBytes > this.maximumBytes
    ) {
      const removed = this.entries.shift();
      if (!removed) {
        break;
      }
      this.retainedBytes -= removed.bytes;
      if (this.readType(removed.payload) === "offer") {
        this.removeWhere((entry) => this.readType(entry.payload) === "ice");
      }
    }
    return this.entries.some((entry) => entry.payload === payload);
  }

  drain(): unknown[] {
    const payloads = this.entries.map((entry) => entry.payload);
    this.clear();
    return payloads;
  }

  clear(): void {
    this.entries.length = 0;
    this.retainedBytes = 0;
  }

  private hasMatchingQueuedOffer(payload: unknown): boolean {
    const record = this.asRecord(payload);
    if (!record) {
      return false;
    }
    for (let index = this.entries.length - 1; index >= 0; index -= 1) {
      const queued = this.asRecord(this.entries[index].payload);
      if (queued?.type !== "offer") {
        continue;
      }
      return (
        queued.tabId === record.tabId &&
        queued.videoId === record.videoId &&
        queued.generation === record.generation
      );
    }
    return false;
  }

  private removeWhere(
    predicate: (entry: { payload: unknown; bytes: number }) => boolean,
  ): void {
    for (let index = this.entries.length - 1; index >= 0; index -= 1) {
      if (!predicate(this.entries[index])) {
        continue;
      }
      this.retainedBytes -= this.entries[index].bytes;
      this.entries.splice(index, 1);
    }
  }

  private serializedByteCount(payload: unknown): number | null {
    try {
      const value =
        payload && typeof payload === "object"
          ? {
              ...(payload as Record<string, unknown>),
              version: this.protocolVersion,
            }
          : payload;
      return new TextEncoder().encode(JSON.stringify(value)).byteLength;
    } catch {
      return null;
    }
  }

  private readType(payload: unknown): string | null {
    const value = this.asRecord(payload)?.type;
    return typeof value === "string" ? value : null;
  }

  private asRecord(payload: unknown): Record<string, unknown> | null {
    return typeof payload === "object" && payload !== null
      ? (payload as Record<string, unknown>)
      : null;
  }
}

class CompanionAuthenticationSession {
  private state:
    | "awaitingChallenge"
    | "awaitingResult"
    | "authenticated"
    | "closed" = "awaitingChallenge";

  constructor(
    private readonly origin: string,
    private readonly secret: string | null,
  ) {}

  async handle(message: unknown): Promise<AuthenticationAction> {
    if (!message || typeof message !== "object") {
      this.state = "closed";
      return { closeCode: 1008, status: "disconnected" };
    }
    const record = message as Record<string, unknown>;

    if (this.state === "awaitingChallenge") {
      if (
        record.type !== "authChallenge" ||
        record.version !== 2 ||
        record.origin !== this.origin ||
        typeof record.nonce !== "string"
      ) {
        this.state = "closed";
        return { closeCode: 1008, status: "disconnected" };
      }
      if (!this.secret) {
        this.state = "closed";
        return { closeCode: 4001, status: "unpaired" };
      }
      try {
        const proof = await authenticationProof(
          this.secret,
          this.origin,
          record.nonce,
        );
        this.state = "awaitingResult";
        return {
          send: {
            type: "authResponse",
            version: 2,
            proof,
          },
          status: "authenticating",
        };
      } catch {
        this.state = "closed";
        return { closeCode: 1008, status: "unpaired" };
      }
    }

    if (this.state === "awaitingResult") {
      if (
        record.type === "authResult" &&
        record.version === 2 &&
        record.authenticated === true
      ) {
        this.state = "authenticated";
        return { authenticated: true, status: "connected" };
      }
      this.state = "closed";
      return { closeCode: 1008, status: "disconnected" };
    }

    if (this.state === "authenticated") {
      return { status: "connected" };
    }
    return { closeCode: 1008, status: "disconnected" };
  }

  get isAuthenticated(): boolean {
    return this.state === "authenticated";
  }
}

class ReconnectBackoff {
  private attempt = 0;

  nextDelayMilliseconds(): number {
    const delay = Math.min(30_000, 1_000 * 2 ** this.attempt);
    this.attempt = Math.min(this.attempt + 1, 5);
    return delay;
  }

  reset(): void {
    this.attempt = 0;
  }
}

const FloatSecurityAPI = {
  encodeBase64URL,
  decodeBase64URL,
  canonicalAuthenticationInput,
  authenticationProof,
  validatePairingSecret,
  randomHandshakeSubprotocol,
  isTrustedExtensionPageSender,
  PairingCredentialRepository,
  IndexedDBPairingCredentialStore,
  BoundedProtocolMessageQueue,
  CompanionAuthenticationSession,
  ReconnectBackoff,
};

(globalThis as any).FloatSecurity = FloatSecurityAPI;
