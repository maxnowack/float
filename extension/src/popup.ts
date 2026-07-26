const popupExt: any = (globalThis as any).chrome ?? (globalThis as any).browser;

const statusElement = document.querySelector<HTMLParagraphElement>("#status");
const formElement = document.querySelector<HTMLFormElement>("#pairing-form");
const inputElement = document.querySelector<HTMLInputElement>("#pairing-secret");
const validationElement = document.querySelector<HTMLParagraphElement>("#validation");
const saveButton = document.querySelector<HTMLButtonElement>("#save");
const removeButton = document.querySelector<HTMLButtonElement>("#remove");

function updateStatus(
  status: "disconnected" | "unpaired" | "authenticating" | "connected",
): void {
  if (!statusElement) {
    return;
  }
  const labels = {
    disconnected: "Companion disconnected",
    unpaired: "Pairing required",
    authenticating: "Authenticating…",
    connected: "Connected",
  };
  statusElement.textContent = labels[status];
  statusElement.className = `status ${status}`;
}

async function refresh(): Promise<void> {
  try {
    const response = await popupExt.runtime.sendMessage({
      type: "float:pairing:status:get",
    });
    const status = response?.status;
    const paired = response?.paired === true;
    if (removeButton) {
      removeButton.hidden = !paired;
    }
    if (saveButton) {
      saveButton.textContent = paired ? "Replace pairing" : "Pair with Float";
    }
    if (
      status === "disconnected" ||
      status === "unpaired" ||
      status === "authenticating" ||
      status === "connected"
    ) {
      updateStatus(status);
      return;
    }
  } catch {
    // Fall through to an unavailable background context.
  }
  updateStatus("disconnected");
}

formElement?.addEventListener("submit", (event) => {
  event.preventDefault();
  const value = inputElement?.value.trim() ?? "";
  if (!FloatSecurity.validatePairingSecret(value)) {
    if (validationElement) {
      validationElement.textContent =
        "Paste the complete pairing secret copied from the Float menu.";
    }
    return;
  }
  if (validationElement) {
    validationElement.textContent = "";
  }
  if (saveButton) {
    saveButton.disabled = true;
  }
  void popupExt.runtime
    .sendMessage({ type: "float:pairing:save", secret: value })
    .then(async (response: unknown) => {
      if (
        !response ||
        typeof response !== "object" ||
        (response as Record<string, unknown>).ok !== true
      ) {
        throw new Error("Credential save failed");
      }
      if (inputElement) {
        inputElement.value = "";
      }
      updateStatus("authenticating");
      await refresh();
    })
    .catch(() => {
      if (validationElement) {
        validationElement.textContent = "Float could not save the pairing secret.";
      }
    })
    .finally(() => {
      if (saveButton) {
        saveButton.disabled = false;
      }
    });
});

removeButton?.addEventListener("click", () => {
  removeButton.disabled = true;
  void popupExt.runtime
    .sendMessage({ type: "float:pairing:remove" })
    .then(async (response: unknown) => {
      if (
        !response ||
        typeof response !== "object" ||
        (response as Record<string, unknown>).ok !== true
      ) {
        throw new Error("Credential removal failed");
      }
      updateStatus("unpaired");
      await refresh();
    })
    .finally(() => {
      removeButton.disabled = false;
    });
});

popupExt.runtime.onMessage.addListener((message: unknown) => {
  if (!message || typeof message !== "object") {
    return;
  }
  const record = message as Record<string, unknown>;
  if (record.type !== "float:pairing:status") {
    return;
  }
  const status = record.status;
  if (
    status === "disconnected" ||
    status === "unpaired" ||
    status === "authenticating" ||
    status === "connected"
  ) {
    updateStatus(status);
  }
});

void refresh();
