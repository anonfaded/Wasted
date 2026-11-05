export const $ = (selector) => document.querySelector(selector);

let toastTimer;

export function toast(message, tone = "info") {
  const element = $("#toast");
  element.textContent = message;
  element.dataset.tone = message ? tone : "";
  element.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    element.hidden = true;
  }, 4500);
}

export function showMessage(selector, message, tone = "info") {
  const element = $(selector);
  if (!element) return;
  element.textContent = message;
  element.dataset.tone = message ? tone : "";
}

export function clearMessage(selector) {
  showMessage(selector, "");
}

export async function copyText(value) {
  const text = String(value ?? "");
  if (!text) throw new Error("Nothing to copy.");
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch (_) {
      // Browser permission can be denied; fall through to the legacy copy path.
    }
  }

  const field = document.createElement("textarea");
  field.value = text;
  field.setAttribute("readonly", "");
  field.style.position = "fixed";
  field.style.opacity = "0";
  document.body.append(field);
  field.select();
  try {
    if (!document.execCommand("copy")) throw new Error("Copy failed.");
  } finally {
    field.remove();
  }
}

const busyLabels = new WeakMap();

export function setBusy(button, busy, busyLabel = "Working…") {
  if (!button) return;
  const label = button.querySelector(".button-label") ?? button;
  if (busy) {
    if (!busyLabels.has(button)) busyLabels.set(button, label.textContent);
    button.disabled = true;
    label.textContent = busyLabel;
  } else {
    button.disabled = false;
    const original = busyLabels.get(button);
    if (original !== undefined) label.textContent = original;
  }
}

/**
 * Promise-based confirmation dialog. When typedPhrase is provided the Confirm button stays
 * disabled until the phrase is typed exactly (Force Reset safety requirement).
 */
export function confirmAction({
  title,
  message,
  typedPhrase = null,
  confirmLabel = "Confirm",
  danger = true,
}) {
  return new Promise((resolve) => {
    const dialog = $("#confirm-dialog");
    const ok = $("#confirm-ok");
    const typedField = $("#confirm-typed-field");
    const typed = $("#confirm-typed");
    const phrase = $("#confirm-phrase");

    $("#confirm-title").textContent = title;
    $("#confirm-message").textContent = message;
    ok.textContent = confirmLabel;
    ok.classList.toggle("danger", danger);
    ok.classList.toggle("primary", !danger);
    const needsTyping = Boolean(typedPhrase);
    typedField.hidden = !needsTyping;
    typed.value = "";
    if (needsTyping) phrase.textContent = typedPhrase;
    ok.disabled = needsTyping;

    const onInput = () => {
      ok.disabled = needsTyping && typed.value.trim() !== typedPhrase;
    };
    typed.oninput = onInput;

    const onClose = () => {
      dialog.removeEventListener("close", onClose);
      resolve(dialog.returnValue === "ok" && (!needsTyping || typed.value.trim() === typedPhrase));
    };
    dialog.addEventListener("close", onClose);
    dialog.returnValue = "";
    dialog.showModal();
  });
}
