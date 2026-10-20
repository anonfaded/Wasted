export const RESET_TIMER = "reset_timer";
export const FORCE_RESET = "force_reset";

/** One idempotency UUID per deliberate submission; retries reuse it to avoid duplicates. */
export function newIdempotencyKey() {
  return crypto.randomUUID();
}

export async function createAction(client, actionType, idempotencyKey) {
  const { data, error } = await client.rpc("create_account_action", {
    p_action_type: actionType,
    p_idempotency_key: idempotencyKey,
  });
  if (error) throw new Error(error.message);
  return data;
}
