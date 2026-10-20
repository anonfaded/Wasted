export const $ = (selector) => document.querySelector(selector);

let toastTimer;

export function toast(message) {
  const element = $("#toast");
  element.textContent = message;
  element.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    element.hidden = true;
  }, 4500);
}

export function showMessage(selector, message) {
  const element = $(selector);
  if (element) element.textContent = message;
}

export function clearMessage(selector) {
  showMessage(selector, "");
}

const busyLabels = new WeakMap();

export function setBusy(button, busy, busyLabel = "Working…") {
  if (!button) return;
  if (busy) {
    if (!busyLabels.has(button)) busyLabels.set(button, button.textContent);
    button.disabled = true;
    button.textContent = busyLabel;
  } else {
    button.disabled = false;
    const original = busyLabels.get(button);
    if (original) button.textContent = original;
  }
}

/**
 * Promise-based confirmation dialog. When typedPhrase is provided the Confirm button stays
 * disabled until the phrase is typed exactly (Force Reset safety requirement).
 */
export function confirmAction({ title, message, typedPhrase = null }) {
  return new Promise((resolve) => {
    const dialog = $("#confirm-dialog");
    const ok = $("#confirm-ok");
    const typedField = $("#confirm-typed-field");
    const typed = $("#confirm-typed");
    const phrase = $("#confirm-phrase");

    $("#confirm-title").textContent = title;
    $("#confirm-message").textContent = message;
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
