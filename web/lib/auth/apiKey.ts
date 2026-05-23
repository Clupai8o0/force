import { createAdminClient } from "@/lib/supabase/admin";
import { hashKey, type Scope } from "@/lib/api-keys";

export type AuthOk = {
  ok: true;
  userId: string;
  scopes: string[];
  keyId: string;
};

export type AuthErr = {
  ok: false;
  status: number;
  error: string;
};

const LAST_USED_DEBOUNCE_MS = 60_000;
const lastTouch = new Map<string, number>();

export async function authenticate(
  req: Request,
  required: Scope | null
): Promise<AuthOk | AuthErr> {
  const header = req.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer\s+(\S+)$/i);
  if (!match) {
    return { ok: false, status: 401, error: "Missing bearer token" };
  }
  const raw = match[1];
  const supabase = createAdminClient();
  const hash = hashKey(raw);

  const { data, error } = await supabase
    .from("api_keys")
    .select("id, user_id, scopes, revoked_at, expires_at")
    .eq("key_hash", hash)
    .maybeSingle();

  if (error || !data) {
    return { ok: false, status: 401, error: "Invalid API key" };
  }
  if (data.revoked_at) {
    return { ok: false, status: 401, error: "Key has been revoked" };
  }
  if (data.expires_at && new Date(data.expires_at).getTime() <= Date.now()) {
    return { ok: false, status: 401, error: "Key has expired" };
  }

  const scopes = (data.scopes as string[]) ?? [];
  if (required && !scopes.includes(required)) {
    return {
      ok: false,
      status: 403,
      error: `Key is missing the '${required}' scope`,
    };
  }

  const now = Date.now();
  const last = lastTouch.get(data.id) ?? 0;
  if (now - last >= LAST_USED_DEBOUNCE_MS) {
    lastTouch.set(data.id, now);
    // Fire-and-forget — we don't want to block the request on the bookkeeping
    // write, and a failed update is harmless.
    void supabase
      .from("api_keys")
      .update({ last_used_at: new Date(now).toISOString() })
      .eq("id", data.id);
  }

  return {
    ok: true,
    userId: data.user_id as string,
    scopes,
    keyId: data.id as string,
  };
}

export function authError(auth: AuthErr): Response {
  return Response.json({ error: auth.error }, { status: auth.status });
}
