import { authenticate, authError } from "@/lib/auth/apiKey";
import { createAdminClient } from "@/lib/supabase/admin";
import { badRequest, readJson, serverError } from "@/lib/api-utils";
import { type Goal, slugId } from "@/lib/content";

export async function GET(req: Request) {
  const auth = await authenticate(req, "goals:read");
  if (!auth.ok) return authError(auth);

  const supabase = createAdminClient();
  const { data, error } = await supabase
    .from("contents")
    .select("goals")
    .eq("user_id", auth.userId)
    .maybeSingle();

  if (error) return serverError(error.message);
  return Response.json({ goals: (data?.goals as Goal[]) ?? [] });
}

export async function PUT(req: Request) {
  const auth = await authenticate(req, "goals:write");
  if (!auth.ok) return authError(auth);

  const body = await readJson(req);
  const raw = body?.goals;
  if (!Array.isArray(raw)) {
    return badRequest("Body must be { goals: Goal[] }");
  }

  const seen = new Set<string>();
  const goals: Goal[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") {
      return badRequest("Each goal must be an object");
    }
    const obj = item as { id?: unknown; label?: unknown };
    const label = typeof obj.label === "string" ? obj.label : "";
    if (!label.trim()) return badRequest("Each goal needs a label");
    let id =
      typeof obj.id === "string" && obj.id.trim() ? obj.id.trim() : slugId(label);
    while (seen.has(id)) id = `${id}-${Math.random().toString(36).slice(2, 5)}`;
    seen.add(id);
    goals.push({ id, label });
  }

  const supabase = createAdminClient();
  const { error } = await supabase
    .from("contents")
    .upsert({ user_id: auth.userId, goals }, { onConflict: "user_id" });
  if (error) return serverError(error.message);

  return Response.json({ goals });
}
