import { $, toast, setBusy, clearMessage, showMessage } from "./ui.js";
import {
  initializeOwnerAccount,
  validateHandle,
} from "./account.js";

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

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
    const validation = validateSignIn(
      $("#sign-in-email").value,
      $("#sign-in-password").value,
    );
    if (validation) {
      showMessage(message, validation.message, "error");
      document.getElementById(validation.field)?.focus();
      return;
    }
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
      toast("Signed in.", "success");
    } catch (error) {
      showMessage(message, error.message, "error");
    } finally {
      setBusy(button, false);
    }
  });

  createForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const validation = validateCreateAccount(
      $("#create-email").value,
      $("#create-password").value,
      $("#create-password-confirm").value,
      $("#create-handle").value,
    );
    if (validation) {
      showMessage(message, validation.message, "error");
      document.getElementById(validation.field)?.focus();
      return;
    }
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
      $("#create-password-confirm").value = "";
      if (!session) {
        throw new Error(
          "Account creation did not complete. Ensure Confirm email is disabled and the single-owner Auth Hook is enabled.",
        );
      }
      toast("Owner account created.", "success");
    } catch (error) {
      showMessage(message, error.message, "error");
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
  if (error) throw authError(error.message, error.code);
  return data.session;
}

export async function createAccount(client, email, password, handle) {
  const handleError = validateHandle(handle);
  if (handleError) throw new Error(handleError);
  const trimmedHandle = String(handle).trim();
  const { data, error } = await client.auth.signUp({
    email: normalizeEmail(email),
    password,
    options: { data: { handle: trimmedHandle } },
  });
  if (error) throw authError(error.message, error.code);
  if (!data.session) {
    throw new Error(
      "Account creation did not complete. Ensure Confirm email is disabled and the single-owner Auth Hook is enabled.",
    );
  }
  await initializeOwnerAccount(client, trimmedHandle);
  return data.session;
}

export function validateSignIn(email, password) {
  const emailError = validateEmail(email, "sign-in-email");
  if (emailError) return emailError;
  if (!password) {
    return { field: "sign-in-password", message: "Enter your password." };
  }
  return null;
}

export function validateCreateAccount(email, password, confirmation, handle) {
  const emailError = validateEmail(email, "create-email");
  if (emailError) return emailError;
  if (!password) {
    return { field: "create-password", message: "Enter a password." };
  }
  if (password.length < 12) {
    return {
      field: "create-password",
      message: "Password must be at least 12 characters.",
    };
  }
  if (!confirmation) {
    return {
      field: "create-password-confirm",
      message: "Confirm your password.",
    };
  }
  if (password !== confirmation) {
    return {
      field: "create-password-confirm",
      message: "Passwords do not match.",
    };
  }
  const handleError = validateHandle(handle);
  if (handleError) return { field: "create-handle", message: handleError };
  return null;
}

export function validateEmail(value, field = "sign-in-email") {
  const email = normalizeEmail(value);
  if (!email) return { field, message: "Enter your email address." };
  if (!EMAIL_PATTERN.test(email)) {
    return { field, message: "Enter a valid email address." };
  }
  return null;
}

export async function signOut(client) {
  await client.auth.signOut();
}

export function normalizeEmail(value) {
  let cleaned = String(value ?? "")
    .replace(/\s+/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9@._%+-]/g, "");
  const at = cleaned.indexOf("@");
  if (at >= 0) {
    cleaned = cleaned.slice(0, at + 1) + cleaned.slice(at + 1).replace(/@/g, "");
  }
  return cleaned;
}


function cleanEmailInsertion(input, data, start, end) {
  let cleaned = normalizeEmail(data);
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

function authError(message, code) {
  const text = String(message || "Authentication failed.");
  const normalizedCode = String(code || "").toLowerCase();
  return new Error(friendlyAuthError(text, normalizedCode));
}

export function friendlyAuthError(message) {
  const text = String(message || "Authentication failed.");
  if (/already has an owner|owner account already initialized/i.test(text)) {
    return "This dashboard already has an owner. Sign in instead.";
  }
  if (/database error saving new user|hook/i.test(text)) {
    return "Account could not be created. The dashboard may already have an owner; sign in instead.";
  }
  if (/invalid login credentials/i.test(text)) return "Wrong email or password.";
  if (/already registered|already exists/i.test(text)) {
    return "This email is already registered. Sign in instead.";
  }
  if (/password should be|weak password/i.test(text)) {
    return "Password rejected: use at least 12 characters with mixed character classes.";
  }
  if (/rate limit|too many/i.test(text)) {
    return "Too many attempts. Wait a moment and try again.";
  }
  if (/failed to fetch|network|load failed/i.test(text)) {
    return "Could not reach Supabase. Check your connection and try again.";
  }
  return text;
}
