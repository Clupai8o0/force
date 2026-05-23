import { authenticate, authError } from "@/lib/auth/apiKey";
import { createAdminClient } from "@/lib/supabase/admin";
import { badRequest, readJson, serverError } from "@/lib/api-utils";

export async function GET(req: Request) {
  const auth = await authenticate(req, "quotes:read");
  if (!auth.ok) return authError(auth);

  const supabase = createAdminClient();
  const { data, error } = await supabase
    .from("contents")
    .select("quotes")
    .eq("user_id", auth.userId)
    .maybeSingle();

  if (error) return serverError(error.message);
  return Response.json({ quotes: (data?.quotes as string[]) ?? [] });
}

export async function POST(req: Request) {
  const auth = await authenticate(req, "quotes:write");
  if (!auth.ok) return authError(auth);

  const body = await readJson(req);
  const text = body && typeof body.text === "string" ? body.text.trim() : "";
  if (!text) return badRequest("Body must be { text: string }");

  const supabase = createAdminClient();
  const { data: existing, error: readErr } = await supabase
    .from("contents")
    .select("quotes")
    .eq("user_id", auth.userId)
    .maybeSingle();
  if (readErr) return serverError(readErr.message);

  const next = [...((existing?.quotes as string[]) ?? []), text];
  const { error: writeErr } = await supabase
    .from("contents")
    .upsert(
      { user_id: auth.userId, quotes: next },
      { onConflict: "user_id" }
    );
  if (writeErr) return serverError(writeErr.message);

  return Response.json({ quotes: next, index: next.length - 1 }, { status: 201 });
}
