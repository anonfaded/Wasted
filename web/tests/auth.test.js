import test from "node:test";
import assert from "node:assert/strict";
import {
  createAccount,
  friendlyAuthError,
  normalizeEmail,
  resendConfirmation,
  signIn,
  validateCreateAccount,
  validateSignIn,
} from "../src/auth.js";

test("normalizeEmail trims, lowercases, and removes whitespace", () => {
  assert.equal(normalizeEmail("  Test @Example.COM  "), "test@example.com");
});

test("normalizeEmail keeps one at-sign and removes other invalid characters", () => {
  assert.equal(normalizeEmail("a@@b.com<script>"), "a@b.comscript");
});

test("normalizeEmail preserves common valid local-part characters", () => {
  assert.equal(normalizeEmail("First.Last+tag@example.co.uk"), "first.last+tag@example.co.uk");
});

test("sign-in validation names the exact field", () => {
  assert.deepEqual(validateSignIn("admin", "secret"), {
    field: "sign-in-email",
    message: "Enter a valid email address.",
  });
  assert.deepEqual(validateSignIn("owner@example.com", ""), {
    field: "sign-in-password",
    message: "Enter your password.",
  });
  assert.equal(validateSignIn("owner@example.com", "secret"), null);
});

test("create-account validation checks password confirmation and handle", () => {
  assert.deepEqual(
    validateCreateAccount("owner@example.com", "short", "short", "Alex"),
    { field: "create-password", message: "Password must be at least 12 characters." },
  );
  assert.deepEqual(
    validateCreateAccount("owner@example.com", "long-enough-1", "different-1", "Alex"),
    { field: "create-password-confirm", message: "Passwords do not match." },
  );
  assert.deepEqual(
    validateCreateAccount("owner@example.com", "long-enough-1", "long-enough-1", ""),
    { field: "create-handle", message: "Enter an account name." },
  );
  assert.equal(
    validateCreateAccount("owner@example.com", "long-enough-1", "long-enough-1", "John Doe"),
    null,
  );
});

test("signup stores the handle in Supabase auth metadata", async () => {
  globalThis.window = { location: { origin: "https://dashboard.test", pathname: "/" } };
  let payload = null;
  const client = {
    auth: {
      signUp: async (value) => {
        payload = value;
        return { data: { session: null }, error: null };
      },
    },
    rpc: async () => {
      throw new Error("RPC must not run without a session");
    },
  };

  assert.equal(await createAccount(client, "Owner@Example.com", "long-enough-1", " Alex "), null);
  assert.equal(payload.email, "owner@example.com");
  assert.equal(payload.options.emailRedirectTo, "https://dashboard.test/");
  assert.deepEqual(payload.options.data, { handle: "Alex" });
});

test("immediate signup session initializes the owner row", async () => {
  globalThis.window = { location: { origin: "https://dashboard.test", pathname: "/" } };
  const calls = [];
  const client = {
    auth: {
      signUp: async () => ({ data: { session: { access_token: "token" } }, error: null }),
      updateUser: async () => ({ error: null }),
    },
    rpc: async (name, params) => {
      calls.push({ name, params });
      return { data: { handle: "Alex" }, error: null };
    },
  };

  const session = await createAccount(client, "owner@example.com", "long-enough-1", "Alex");
  assert.ok(session);
  assert.deepEqual(calls, [
    { name: "initialize_owner_account", params: { p_handle: "Alex" } },
  ]);
});

test("an obfuscated existing-user signup is reported clearly", async () => {
  globalThis.window = { location: { origin: "https://dashboard.test", pathname: "/" } };
  const client = {
    auth: {
      signUp: async () => ({
        data: { session: null, user: { identities: [] } },
        error: null,
      }),
    },
    rpc: async () => {
      throw new Error("RPC must not run without a session");
    },
  };

  await assert.rejects(
    () => createAccount(client, "owner@example.com", "long-enough-1", "Alex"),
    /may already exist/,
  );
});

test("unconfirmed email is mapped and tagged for the resend action", async () => {
  const client = {
    auth: {
      signInWithPassword: async () => ({
        data: null,
        error: { message: "Email not confirmed", code: "email_not_confirmed" },
      }),
    },
  };
  await assert.rejects(
    () => signIn(client, "owner@example.com", "long-enough-1"),
    (error) =>
      error.code === "EMAIL_NOT_CONFIRMED" &&
      /Confirm your email address first/.test(error.message),
  );
});

test("resend confirmation forwards the normalized email", async () => {
  globalThis.window = { location: { origin: "https://dashboard.test", pathname: "/" } };
  let payload = null;
  const client = {
    auth: {
      resend: async (value) => {
        payload = value;
        return { error: null };
      },
    },
  };
  await resendConfirmation(client, " Owner@Example.com ");
  assert.deepEqual(payload, {
    type: "signup",
    email: "owner@example.com",
    options: { emailRedirectTo: "https://dashboard.test/" },
  });
});

test("auth errors are translated without changing unknown messages", () => {
  assert.equal(friendlyAuthError("Invalid login credentials"), "Wrong email or password.");
  assert.equal(
    friendlyAuthError("Failed to fetch"),
    "Could not reach Supabase. Check your connection and try again.",
  );
  assert.equal(friendlyAuthError("Custom backend error"), "Custom backend error");
});
