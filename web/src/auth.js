import { $, toast, setBusy, clearMessage, showMessage } from "./ui.js";

/** Auth flows: separate Sign In and Create Account forms; a failed sign-in never creates one. */
export function wireAuth(client) {
  const signInForm = $("#sign-in-form");
  const createForm = $("#create-account-form");
  const signInLine = $("#show-sign-in-line");
  const createLine = $("#show-create-line");
  const title = $("#auth-title");
  const subtitle = $("#auth-subtitle");
  const message = "#auth-message";

  const showMode = (mode) => {
    const create = mode === "create";
    signInForm.hidden = create;
    createForm.hidden = !create;
    createLine.hidden = create;
    signInLine.hidden = !create;
    title.textContent = create ? "Create Account" : "Sign In";
    subtitle.textContent = create
      ? "Create an account to manage your devices."
      : "Sign in to manage your devices.";
    clearMessage(message);
  };

  $("#show-create").addEventListener("click", () => showMode("create"));
  $("#show-sign-in").addEventListener("click", () => showMode("sign-in"));

  for (const input of [$("#sign-in-email"), $("#create-email")]) {
    if (!input) continue;
    input.addEventListener("beforeinput", (event) => {
      if (!event.data || (event.inputType ?? "").startsWith("delete")) return;
      const start = input.selectionStart ?? input.value.length;
      const end = input.selectionEnd ?? start;
      const cleaned = cleanEmailInsertion(input, event.data, start, end);
      if (cleaned === event.data) return;
      event.preventDefault();
      if (!cleaned) return;
      const next = input.value.slice(0, start) + cleaned + input.value.slice(end);
      input.value = next;
      const position = start + cleaned.length;
      input.setSelectionRange(position, position);
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    input.addEventListener("input", () => sanitizeEmailInput(input));
    input.addEventListener("blur", () => sanitizeEmailInput(input));
    input.addEventListener("keydown", (event) => {
      if (event.key.length === 1 && !/[a-zA-Z0-9@._%+-]/.test(event.key)) {
        event.preventDefault();
      }
    });
  }

  for (const toggle of document.querySelectorAll("[data-password-toggle]")) {
    toggle.addEventListener("click", () => {
      const input = document.getElementById(toggle.dataset.passwordToggle);
      if (!input) return;
      const show = input.type === "password";
      input.type = show ? "text" : "password";
      toggle.setAttribute("aria-pressed", String(show));
      toggle.setAttribute("aria-label", show ? "Hide password" : "Show password");
    });
  }

  signInForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!signInForm.reportValidity()) return;
    clearMessage(message);
    const button = $("#sign-in");
    setBusy(button, true);
    try {
      await signIn(
        client,
        $("#sign-in-email").value.trim(),
        $("#sign-in-password").value,
      );
      $("#sign-in-password").value = "";
      toast("Signed in.");
    } catch (error) {
      showMessage(message, error.message);
    } finally {
      setBusy(button, false);
    }
  });

  createForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!createForm.reportValidity()) return;
    clearMessage(message);
    const button = $("#create-account");
    setBusy(button, true);
    try {
      const session = await createAccount(
        client,
        $("#create-email").value.trim(),
        $("#create-password").value,
        $("#create-handle").value.trim(),
      );
      $("#create-password").value = "";
      if (session) {
        toast("Account created.");
      } else {
        showMode("sign-in");
        showMessage(message, "Check your email for the confirmation link, then sign in.");
      }
    } catch (error) {
      showMessage(message, error.message);
    } finally {
      setBusy(button, false);
    }
  });
}

export async function currentSession(client) {
  const { data } = await client.auth.getSession();
  return data.session ?? null;
}

export function onAuthChange(client, callback) {
  const { data } = client.auth.onAuthStateChange((_event, session) => callback(session));
  return () => data.subscription.unsubscribe();
}

export async function signIn(client, email, password) {
  const { data, error } = await client.auth.signInWithPassword({
    email: normalizeEmail(email),
    password,
  });
  if (error) throw new Error(friendlyAuthError(error.message));
  return data.session;
}

export async function createAccount(client, email, password, handle) {
  if (!handle || !/^[A-Za-z0-9][A-Za-z0-9_.-]{2,31}$/.test(handle)) {
    throw new Error("Use 3-32 characters: letters, digits, dot, dash, underscore.");
  }
  const redirectTo = `${window.location.origin}${window.location.pathname}`;
  const { data, error } = await client.auth.signUp({
    email: normalizeEmail(email),
    password,
    options: { emailRedirectTo: redirectTo },
  });
  if (error) throw new Error(friendlyAuthError(error.message));
  if (!data.session) {
    try {
      localStorage.setItem("wasted_pending_handle", handle);
    } catch {
      // Storage is optional; the setup form still asks for the handle.
    }
    return null;
  }
  const { error: rpcError } = await client.rpc("initialize_owner_account", { p_handle: handle });
  if (rpcError) throw new Error(friendlyAuthError(rpcError.message));
  return data.session;
}

export async function signOut(client) {
  await client.auth.signOut();
}

function normalizeEmail(value) {
  return String(value ?? "")
    .replace(/\s+/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9@._%+-]/g, "");
}

function cleanEmailInsertion(input, data, start, end) {
  let cleaned = String(data).replace(/\s+/g, "").toLowerCase()
    .replace(/[^a-z0-9@._%+-]/g, "");
  const base = input.value.slice(0, start) + input.value.slice(end);
  if (base.includes("@")) cleaned = cleaned.replace(/@/g, "");
  if (!base && cleaned.startsWith("@")) cleaned = cleaned.replace(/^@+/, "");
  return cleaned;
}

function sanitizeEmailInput(input) {
  const original = input.value;
  const cleaned = normalizeEmail(original);
  if (cleaned === original) return;
  const start = input.selectionStart ?? original.length;
  const removedBeforeCursor = (original.slice(0, start).match(/\s|[^a-z0-9@._%+-]/gi) ?? []).length;
  input.value = cleaned;
  const position = Math.max(0, Math.min(cleaned.length, start - removedBeforeCursor));
  input.setSelectionRange(position, position);
}

function friendlyAuthError(message) {
  const text = String(message || "Authentication failed.");
  if (/invalid login credentials/i.test(text)) return "Wrong email or password.";
  if (/already registered|already exists/i.test(text)) {
    return "An account with this email already exists — sign in instead.";
  }
  if (/password should be|weak password/i.test(text)) {
    return "Password rejected: use at least 12 characters with mixed character classes.";
  }
  if (/rate limit/i.test(text)) return "Too many attempts. Wait a moment and try again.";
  return text;
}
