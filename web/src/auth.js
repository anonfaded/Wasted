import { $, toast, setBusy, clearMessage, showMessage } from "./ui.js";

/** Auth flows: explicit Sign In and Create Account. A failed sign-in never creates an account. */
export function wireAuth(client) {
  const form = $("#auth-form");
  const email = $("#email");
  const password = $("#password");
  const handle = $("#handle");
  const handleField = $("#handle-field");
  const signInButton = $("#sign-in");
  const createButton = $("#create-account");
  let mode = "sign-in";

  const setMode = (next) => {
    mode = next;
    handleField.hidden = next !== "create";
    handle.required = next === "create";
    clearMessage("#auth-message");
  };
  createButton.addEventListener("click", () =>
    setMode(mode === "create" ? "sign-in" : "create"),
  );

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!form.reportValidity()) return;
    clearMessage("#auth-message");
    const button = mode === "create" ? createButton : signInButton;
    setBusy(button, true);
    try {
      if (mode === "create") {
        await createAccount(client, email.value.trim(), password.value, handle.value.trim());
        toast("Account created.");
      } else {
        await signIn(client, email.value.trim(), password.value);
        toast("Signed in.");
      }
      password.value = "";
    } catch (error) {
      showMessage("#auth-message", error.message);
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
