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
      await createAccount(
        client,
        $("#create-email").value.trim(),
        $("#create-password").value,
        $("#create-handle").value.trim(),
      );
      $("#create-password").value = "";
      toast("Account created.");
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
  const { data, error } = await client.auth.signInWithPassword({ email, password });
  if (error) throw new Error(friendlyAuthError(error.message));
  return data.session;
}

export async function createAccount(client, email, password, handle) {
  if (!handle || !/^[A-Za-z0-9][A-Za-z0-9_.-]{2,31}$/.test(handle)) {
    throw new Error("Use 3-32 characters: letters, digits, dot, dash, underscore.");
  }
  const { data, error } = await client.auth.signUp({ email, password });
  if (error) throw new Error(friendlyAuthError(error.message));
  if (!data.session) {
    throw new Error("Sign-up needs email confirmation on this project. Confirm, then sign in.");
  }
  const { error: rpcError } = await client.rpc("initialize_owner_account", { p_handle: handle });
  if (rpcError) throw new Error(friendlyAuthError(rpcError.message));
  return data.session;
}

export async function signOut(client) {
  await client.auth.signOut();
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
