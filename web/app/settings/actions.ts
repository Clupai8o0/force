"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { generateKey, ALL_SCOPES, type Scope } from "@/lib/api-keys";

export type CreateKeyResult =
  | { ok: true; raw: string; prefix: string; name: string }
  | { ok: false; error: string };

export async function createApiKey(input: {
  name: string;
  scopes: string[];
  expiresAt: string | null;
}): Promise<CreateKeyResult> {
  const name = input.name.trim();
  if (!name) return { ok: false, error: "Name is required" };
  if (name.length > 80) return { ok: false, error: "Name is too long" };

  const allowed = new Set<string>(ALL_SCOPES);
  const scopes = input.scopes.filter((s): s is Scope => allowed.has(s));
  if (scopes.length === 0) {
    return { ok: false, error: "Pick at least one scope" };
  }

  let expiresAt: string | null = null;
  if (input.expiresAt) {
    const t = new Date(input.expiresAt);
    if (Number.isNaN(t.getTime())) {
      return { ok: false, error: "Invalid expiry date" };
    }
    if (t.getTime() <= Date.now()) {
      return { ok: false, error: "Expiry must be in the future" };
    }
    expiresAt = t.toISOString();
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not signed in" };

  const { raw, prefix, hash } = generateKey();
  const { error } = await supabase.from("api_keys").insert({
    user_id: user.id,
    name,
    prefix,
    key_hash: hash,
    scopes,
    expires_at: expiresAt,
  });
  if (error) return { ok: false, error: error.message };

  revalidatePath("/settings/api-keys");
  return { ok: true, raw, prefix, name };
}

export async function revokeApiKey(
  id: string
): Promise<{ ok: true } | { ok: false; error: string }> {
  if (!id) return { ok: false, error: "Missing id" };
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not signed in" };

  const { error } = await supabase
    .from("api_keys")
    .update({ revoked_at: new Date().toISOString() })
    .eq("id", id)
    .eq("user_id", user.id);
  if (error) return { ok: false, error: error.message };

  revalidatePath("/settings/api-keys");
  return { ok: true };
}
