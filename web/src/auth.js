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
  const resend = $("#resend-confirmation");

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
    resend.hidden = true;
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
      resend.hidden = true;
      showMessage(message, validation.message, "error");
      document.getElementById(validation.field)?.focus();
      return;
    }
    clearMessage(message);
    resend.hidden = true;
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
      resend.hidden = error.code !== "EMAIL_NOT_CONFIRMED";
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
      resend.hidden = true;
      showMessage(message, validation.message, "error");
      document.getElementById(validation.field)?.focus();
      return;
    }
    clearMessage(message);
    resend.hidden = true;
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
      if (session) {
        toast("Account created.", "success");
      } else {
        showMode("sign-in");
        $("#sign-in-email").value = $("#create-email").value.trim();
        showMessage(
          message,
          "Check your email for the confirmation link, then sign in. If it does not arrive, configure Supabase SMTP.",
          "info",
        );
        resend.hidden = false;
      }
    } catch (error) {
      showMessage(message, error.message, "error");
      resend.hidden = error.code !== "EMAIL_NOT_CONFIRMED";
    } finally {
      setBusy(button, false);
    }
  });

  resend.addEventListener("click", async () => {
    const email = $("#sign-in-email").value.trim();
    const validation = validateEmail(email);
    if (validation) {
      showMessage(message, validation.message, "error");
      $("#sign-in-email").focus();
      return;
    }
    setBusy(resend, true, "Sending…");
    try {
      await resendConfirmation(client, email);
      showMessage(message, "Confirmation email requested. Check your inbox and spam.", "success");
    } catch (error) {
      showMessage(message, error.message, "error");
    } finally {
      setBusy(resend, false, "Resend confirmation email");
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
  const redirectTo = dashboardRedirect();
  const { data, error } = await client.auth.signUp({
    email: normalizeEmail(email),
    password,
    options: {
      emailRedirectTo: redirectTo,
      data: { handle: trimmedHandle },
    },
  });
  if (error) throw authError(error.message, error.code);
  if (!data.session) {
    // Supabase intentionally returns an obfuscated user for an existing email.
    // Do not branch on that response; keep the confirmation UI enumeration-resistant.
    return null;
  }
  await initializeOwnerAccount(client, trimmedHandle);
  return data.session;
}

export async function resendConfirmation(client, email) {
  const { error } = await client.auth.resend({
    type: "signup",
    email: normalizeEmail(email),
    options: { emailRedirectTo: dashboardRedirect() },
  });
  if (error) throw authError(error.message, error.code);
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

function dashboardRedirect() {
  return `${window.location.origin}${window.location.pathname}`;
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
  const error = new Error(friendlyAuthError(text, normalizedCode));
  if (normalizedCode === "email_not_confirmed" || /email not confirmed/i.test(text)) {
    error.code = "EMAIL_NOT_CONFIRMED";
  }
  return error;
}

export function friendlyAuthError(message, code = "") {
  const text = String(message || "Authentication failed.");
  if (code === "email_not_confirmed" || /email not confirmed/i.test(text)) {
    return "Confirm your email address first. Check your inbox for the link, then sign in.";
  }
  if (/invalid login credentials/i.test(text)) return "Wrong email or password.";
  if (/already registered|already exists/i.test(text)) {
    return "If this email is already registered, sign in or resend the confirmation email.";
  }
  if (/owner account already initialized/i.test(text)) {
    return "This dashboard already has an owner. Sign in instead.";
  }
  if (/password should be|weak password/i.test(text)) {
    return "Password rejected: use at least 12 characters with mixed character classes.";
  }
  if (/email_address_not_authorized|email address not authorized/i.test(text)) {
    return "Supabase's built-in email service only sends to project team members. Add this email to the Supabase organization or configure custom SMTP in Authentication → Emails → SMTP Settings.";
  }
  if (/over_email_send_rate_limit|email rate limit exceeded/i.test(text)) {
    return "Supabase's confirmation-email limit was reached. Wait, or configure custom SMTP in Authentication → Emails → SMTP Settings.";
  }
  if (/rate limit|too many/i.test(text)) {
    return "Too many attempts. Wait a moment and try again.";
  }
  if (/failed to fetch|network|load failed/i.test(text)) {
    return "Could not reach Supabase. Check your connection and try again.";
  }
  return text;
}
